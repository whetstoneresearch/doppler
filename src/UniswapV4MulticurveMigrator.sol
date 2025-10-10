// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData, storeBeneficiaries, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { Position } from "src/types/Position.sol";
import { EMPTY_ADDRESS } from "src/types/Constants.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { Curve, adjustCurves, calculatePositions } from "src/libraries/Multicurve.sol";

/**
 * @notice Data to use for the migration
 * @param isToken0 True if the currency0 is the asset we're selling
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 * @param curves Array of curves used to distribute liquidity
 */
struct AssetData {
    bool isToken0;
    PoolKey poolKey;
    uint32 lockDuration;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
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
 * @title Doppler Uniswap V4 Multicurve Migrator
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Migrates liquidity into a fresh Uniswap V4 pool and distributes it across multiple positions,
 * as described in the Doppler Multicurve whitepaper (https://www.doppler.lol/multicurve.pdf)
 */
contract UniswapV4MulticurveMigrator is ILiquidityMigrator, ImmutableAirlock {
    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the Uniswap V4 Migrator hook
    IHooks public immutable migratorHook;

    /// @notice Address of the StreamableFeesLockerV2 contract
    StreamableFeesLockerV2 public immutable locker;

    /// @notice Mapping of asset pairs to their respective asset data
    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of Uniswap V4 PoolManager contract
     * @param migratorHook_ Address of the Migrator hook, note that a fresh deployment
     * is required to set this contract as the migrator address
     * @param locker_ Address of the StreamableFeesLockerV2 contract, note that this contract
     * will have to be approved in the locker
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks migratorHook_,
        StreamableFeesLockerV2 locker_
    ) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        migratorHook = migratorHook_;
        locker = locker_;
    }

    /// @inheritdoc ILiquidityMigrator
    function initialize(address asset, address numeraire, bytes calldata data) external onlyAirlock returns (address) {
        (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves
        ) = abi.decode(data, (uint24, int24, uint32, BeneficiaryData[], Curve[]));

        isTickSpacingValid(tickSpacing);
        LPFeeLibrary.validate(fee);

        // We intentionnaly pass an empty PoolId to avoid storing the shares in this contract
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES, _storeBeneficiary
        );

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: migratorHook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] = AssetData({
            isToken0: Currency.unwrap(poolKey.currency0) == asset,
            poolKey: poolKey,
            lockDuration: lockDuration,
            beneficiaries: beneficiaries,
            curves: curves
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
        AssetData memory data = getAssetData[token0][token1];
        (bool isToken0, int24 tickSpacing) = (data.isToken0, data.poolKey.tickSpacing);
        require(tickSpacing != 0, PoolNotInitialized());

        poolManager.initialize(data.poolKey, sqrtPriceX96);

        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            balance0 = address(this).balance;
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        int24 offset = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        (Curve[] memory adjustedCurves,,) = adjustCurves(data.curves, offset, tickSpacing, !isToken0);
        Position[] memory positions = calculatePositions(
            adjustedCurves, tickSpacing, isToken0 ? balance1 : balance0, isToken0 ? balance0 : balance1, !isToken0
        );

        data.poolKey.currency0.transfer(address(locker), balance0);
        data.poolKey.currency1.transfer(address(locker), balance1);

        locker.lock(data.poolKey, data.lockDuration, recipient, data.beneficiaries, positions);

        emit Migrate(data.isToken0 ? token0 : token1, data.poolKey);

        // Not true per se but this value is not used in the Airlock so we'll return 0 to avoid extra computation
        return 0;
    }

    /// @dev Dummy function to pass to `storeBeneficiaries` since we only want to validate the beneficiaries here
    function _storeBeneficiary(PoolId, BeneficiaryData memory) private { }
}
