// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Curve, Multicurve } from "src/libraries/Multicurve.sol";
import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES, storeBeneficiaries } from "src/types/BeneficiaryData.sol";
import { EMPTY_ADDRESS } from "src/types/Constants.sol";
import { Position } from "src/types/Position.sol";

/**
 * @notice Data to use for the migration
 * @param isToken0 True if the currency0 is the asset we're selling
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 * @param curves Array of curves used to distribute liquidity
 * @param useDynamicFee True if the pool uses dynamic fees
 * @param feeOrInitialDynamicFee Fee for the pool (used as initial dynamic fee if useDynamicFee is true)
 * @param dopplerHook Address of the associated Doppler hook
 * @param onInitializationCalldata Calldata passed to the Doppler hook on initialization
 * @param farTick Farthest tick that must be reached for graduation
 * @param onGraduationCalldata Calldata passed to the Doppler hook on graduation
 */
struct MigrationData {
    bool isToken0;
    PoolKey poolKey;
    uint32 lockDuration;
    BeneficiaryData[] beneficiaries;
    Curve[] curves;
    bool useDynamicFee;
    uint24 feeOrInitialDynamicFee;
    address dopplerHook;
    bytes onInitializationCalldata;
    int24 farTick;
    bytes onGraduationCalldata;
}

/// @notice Thrown when `migrate` is called before `initialize` for a pool
error PoolNotInitialized();

/**
 * @notice Emitted when an asset is migrated
 * @param asset Address of the asset token
 * @param poolKey Pool receiving the migrated liquidity
 */
event Migrate(address indexed asset, PoolKey poolKey);

/**
 * @title Doppler Hook Migrator
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Migrates liquidity into a fresh Uniswap V4 pool with Doppler hook support via DopplerHookInitializer.
 * The destination pool supports swap-time Doppler hooks (e.g., Rehype) and virtual migration via `graduate()`.
 * Liquidity is distributed across multiple positions as described in the Doppler Multicurve whitepaper
 * (https://www.doppler.lol/multicurve.pdf) and managed by the StreamableFeesLockerV2 contract.
 */
contract DopplerHookMigrator is ILiquidityMigrator, ImmutableAirlock {
    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the DopplerHookInitializer contract
    DopplerHookInitializer public immutable dopplerHookInitializer;

    /// @notice Address of the StreamableFeesLockerV2 contract
    StreamableFeesLockerV2 public immutable locker;

    /// @notice Mapping of asset pairs to their respective migration data
    mapping(address token0 => mapping(address token1 => MigrationData data)) public getMigrationData;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of Uniswap V4 PoolManager contract
     * @param dopplerHookInitializer_ Address of the DopplerHookInitializer contract
     * @param locker_ Address of the StreamableFeesLockerV2 contract, note that this contract
     * will have to be approved in the locker
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        DopplerHookInitializer dopplerHookInitializer_,
        StreamableFeesLockerV2 locker_
    ) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        dopplerHookInitializer = dopplerHookInitializer_;
        locker = locker_;
    }

    /// @dev Allows the contract to receive ETH for native token migrations
    receive() external payable { }

    /// @inheritdoc ILiquidityMigrator
    function initialize(address asset, address numeraire, bytes calldata data) external onlyAirlock returns (address) {
        (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            int24 farTick,
            bytes memory onGraduationCalldata
        ) = abi.decode(data, (uint24, int24, uint32, BeneficiaryData[], Curve[], bool, address, bytes, int24, bytes));

        isTickSpacingValid(tickSpacing);

        // Validate fee (for fixed fee pools, validate range; dynamic fee pools accept any initial value)
        if (!useDynamicFee) {
            LPFeeLibrary.validate(feeOrInitialDynamicFee);
        }

        // We intentionally pass an empty PoolId to avoid storing the shares in this contract
        // (validation only; actual storage happens in locker)
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES, _storeBeneficiary
        );

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(address(dopplerHookInitializer)),
            fee: useDynamicFee ? LPFeeLibrary.DYNAMIC_FEE_FLAG : feeOrInitialDynamicFee,
            tickSpacing: tickSpacing
        });

        getMigrationData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] = MigrationData({
            isToken0: Currency.unwrap(poolKey.currency0) == asset,
            poolKey: poolKey,
            lockDuration: lockDuration,
            beneficiaries: beneficiaries,
            curves: curves,
            useDynamicFee: useDynamicFee,
            feeOrInitialDynamicFee: feeOrInitialDynamicFee,
            dopplerHook: dopplerHook,
            onInitializationCalldata: onInitializationCalldata,
            farTick: farTick,
            onGraduationCalldata: onGraduationCalldata
        });

        // Uniswap V4 pools are represented by their PoolKey, so we return an empty address instead
        return EMPTY_ADDRESS;
    }

    /// @inheritdoc ILiquidityMigrator
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256) {
        MigrationData memory data = getMigrationData[token0][token1];
        (bool isToken0, int24 tickSpacing) = (data.isToken0, data.poolKey.tickSpacing);
        require(tickSpacing != 0, PoolNotInitialized());

        // Compute far tick (flip sign if asset is token1)
        int24 farTick = isToken0 ? data.farTick : -data.farTick;

        // Get asset and numeraire addresses
        address asset = isToken0 ? token0 : token1;
        address numeraire = isToken0 ? token1 : token0;

        // Initialize the migration pool via DopplerHookInitializer
        dopplerHookInitializer.initializeMigrationPool(
            asset,
            numeraire,
            data.poolKey,
            sqrtPriceX96,
            farTick,
            data.feeOrInitialDynamicFee,
            data.useDynamicFee,
            data.dopplerHook,
            data.onInitializationCalldata,
            data.onGraduationCalldata
        );

        // Calculate balances
        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            balance0 = address(this).balance;
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        // Adjust curves based on the migration price
        int24 offset = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        (Curve[] memory adjustedCurves,,) = Multicurve.adjustCurves(data.curves, offset, tickSpacing, !isToken0);
        Position[] memory positions = Multicurve.calculatePositions(
            adjustedCurves, tickSpacing, isToken0 ? balance1 : balance0, isToken0 ? balance0 : balance1, !isToken0
        );

        // Transfer tokens to locker and lock the positions
        data.poolKey.currency0.transfer(address(locker), balance0);
        data.poolKey.currency1.transfer(address(locker), balance1);

        locker.lock(data.poolKey, data.lockDuration, recipient, data.beneficiaries, positions);

        emit Migrate(asset, data.poolKey);

        // Not true per se but this value is not used in the Airlock so we'll return 0 to avoid extra computation
        return 0;
    }

    /// @dev Dummy function to pass to `storeBeneficiaries` since we only want to validate the beneficiaries here
    function _storeBeneficiary(PoolId, BeneficiaryData memory) private { }
}
