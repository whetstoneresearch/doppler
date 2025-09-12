// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData, StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { Airlock } from "src/Airlock.sol";

/**
 * @notice Data to use for the migration
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 */
struct AssetData {
    PoolKey poolKey;
    uint32 lockDuration;
    BeneficiaryData[] beneficiaries;
}

/**
 * @dev Emitted when liquidity is migrated
 * @param poolId Pool ID of the new Uniswap V4 pool
 * @param sqrtPriceX96 Square root price of the pool at the time of migration
 * @param lowerTick Lower tick of the full range position
 * @param upperTick Upper tick of the full range position
 * @param liquidity Amount of liquidity added into the new pool
 * @param reserves0 Amount of token0 reserves in the new pool
 * @param reserves1 Amount of token1 reserves in the new pool
 */
event Migrate(
    PoolId indexed poolId,
    uint160 sqrtPriceX96,
    int24 lowerTick,
    int24 upperTick,
    uint256 liquidity,
    uint256 reserves0,
    uint256 reserves1
);

/// @dev Thrown when the tick is out of range for the pool
error TickOutOfRange();

/// @dev Thrown when the computed liquidity is zero
error ZeroLiquidity();

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when protocol owner shares are invalid
error InvalidProtocolOwnerShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when an invalid length is used
error InvalidLength();

/// @dev WAD constant for precise decimal calculations
uint256 constant WAD = 1e18;

/**
 * @title Uniswap V4 Migrator
 * @author Whetstone Research
 * @notice Module contract to migrate liquidity from a Doppler Dutch auction pool to a
 * regular Uniswap V4 pool
 */
contract UniswapV4Migrator is ILiquidityMigrator, ImmutableAirlock {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the Uniswap V4 Position Manager contract
    PositionManager public immutable positionManager;

    /// @notice Address of the Streamable Fees Locker
    StreamableFeesLocker public immutable locker;

    /// @notice Address of the Uniswap V4 Migrator Hook
    IHooks public immutable migratorHook;

    /// @notice Dead address used for no-op governance
    address public constant DEAD_ADDRESS = address(0xdead);

    /// @notice Empty address used to indicate no pool exists (bc v4 is a singleton)
    address public constant EMPTY_ADDRESS = address(0);

    /// @notice Mapping of asset pairs to their respective asset data
    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    /// @notice Anyone can send ETH to this contract
    receive() external payable { }

    /**
     *
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager contract
     * @param positionManager_ Address of the Uniswap V4 Position Manager contract
     * @param locker_ Address of the Streamable Fees Locker contract
     * @param migratorHook_ Address of the Uniswap V4 Migrator Hook contract
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        PositionManager positionManager_,
        StreamableFeesLocker locker_,
        IHooks migratorHook_
    ) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        migratorHook = migratorHook_;
    }

    /// @inheritdoc ILiquidityMigrator
    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        (uint24 fee, int24 tickSpacing, uint32 lockDuration, BeneficiaryData[] memory beneficiaries) =
            abi.decode(liquidityMigratorData, (uint24, int24, uint32, BeneficiaryData[]));

        _validateTickSpacing(tickSpacing);
        LPFeeLibrary.validate(fee);
        _validateBeneficiaries(beneficiaries);

        PoolKey memory poolKey = _createPoolKey(asset, numeraire, fee, tickSpacing);

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] =
            AssetData({ poolKey: poolKey, lockDuration: lockDuration, beneficiaries: beneficiaries });

        return EMPTY_ADDRESS; // v4 pools are represented by their PoolKey, so we return an empty address
    }

    /**
     * @dev Validates tick spacing parameters
     * @param tickSpacing The tick spacing to validate
     */
    function _validateTickSpacing(
        int24 tickSpacing
    ) internal pure {
        require(tickSpacing <= TickMath.MAX_TICK_SPACING, IPoolManager.TickSpacingTooLarge(tickSpacing));
        require(tickSpacing >= TickMath.MIN_TICK_SPACING, IPoolManager.TickSpacingTooSmall(tickSpacing));
    }

    /**
     * @dev Validates beneficiaries array and ensures protocol owner compliance
     * @param beneficiaries Array of beneficiaries to validate
     */
    function _validateBeneficiaries(
        BeneficiaryData[] memory beneficiaries
    ) internal view {
        require(beneficiaries.length > 0, InvalidLength());

        address protocolOwner = Airlock(airlock).owner();
        address prevBeneficiary;
        uint256 totalShares;
        bool foundProtocolOwner;

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            BeneficiaryData memory beneficiary = beneficiaries[i];

            // Validate ordering and shares
            require(prevBeneficiary < beneficiary.beneficiary, UnorderedBeneficiaries());
            require(beneficiary.shares > 0, InvalidShares());

            // Check for protocol owner and validate minimum share requirement
            if (beneficiary.beneficiary == protocolOwner) {
                require(beneficiary.shares >= WAD / 20, InvalidProtocolOwnerShares());
                foundProtocolOwner = true;
            }

            prevBeneficiary = beneficiary.beneficiary;
            totalShares += beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }

    /**
     * @dev Creates a PoolKey struct with proper currency ordering
     * @param asset Asset token address
     * @param numeraire Numeraire token address
     * @param fee Pool fee
     * @param tickSpacing Tick spacing
     * @return poolKey Constructed PoolKey
     */
    function _createPoolKey(
        address asset,
        address numeraire,
        uint24 fee,
        int24 tickSpacing
    ) internal view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: migratorHook,
            fee: fee,
            tickSpacing: tickSpacing
        });
    }

    struct ModifyLiquidityParams {
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint128 amount0;
        uint128 amount1;
        address recipient;
    }

    function _roundDown(
        uint128 value
    ) internal pure returns (uint128) {
        return value == 0 ? 0 : value - 1;
    }

    /// @inheritdoc ILiquidityMigrator
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        AssetData memory assetData = getAssetData[token0][token1];
        PoolKey memory poolKey = assetData.poolKey;

        // Check if this is no-op governance
        bool isNoOpGovernance = recipient == DEAD_ADDRESS;

        int24 currentTick = poolManager.initialize(poolKey, sqrtPriceX96);

        // TODO: Use SafeCasting here
        uint128 balance1 = uint128(ERC20(token1).balanceOf(address(this)));
        uint128 balance0 =
            uint128(token0 == address(0) ? address(this).balance : ERC20(token0).balanceOf(address(this)));

        int24 lowerTick = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(poolKey.tickSpacing);

        // A pool can be initialized at any tick but we want to make sure our current tick is
        // aligned with the tick spacing when we'll add liquidity
        currentTick = currentTick / poolKey.tickSpacing * poolKey.tickSpacing;

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        // We're adding liquidity to two single-sided positions instead of a full range position, this is to ensure
        // we're using as much tokens as possible and will result in more liquidity being added to the pool
        uint128 belowPriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(currentTick - poolKey.tickSpacing),
            0,
            _roundDown(balance1)
        );

        uint128 abovePriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(currentTick + poolKey.tickSpacing),
            TickMath.getSqrtPriceAtTick(upperTick),
            _roundDown(balance0),
            0
        );

        // Total liquidity provided into the pool
        liquidity = belowPriceLiquidity + abovePriceLiquidity;

        // We revert early just in case
        if (liquidity == 0) revert ZeroLiquidity();

        // We may end up with a maximum of 4 positions, let's compute them and see which ones we need to mint
        ModifyLiquidityParams[] memory modifyLiquidityParams = new ModifyLiquidityParams[](4);

        uint128 timelockAbovePriceLiquidity = isNoOpGovernance ? abovePriceLiquidity : abovePriceLiquidity / 10;

        // First one is the above price position for the protocol locker, we'll use 100% of the liquidity if no
        // governance is associated with the asset and only 10% otherwise
        modifyLiquidityParams[0] = ModifyLiquidityParams({
            lowerTick: currentTick + poolKey.tickSpacing,
            upperTick: upperTick,
            liquidity: timelockAbovePriceLiquidity / 2,
            amount0: isNoOpGovernance ? balance0 : balance0 / 10,
            amount1: 0,
            recipient: address(this)
        });

        // If there's a governance, we use the 90% of the liquidity left to mint a position for the Timelock
        modifyLiquidityParams[1] = ModifyLiquidityParams({
            lowerTick: currentTick + poolKey.tickSpacing,
            upperTick: upperTick,
            liquidity: isNoOpGovernance ? 0 : abovePriceLiquidity - timelockAbovePriceLiquidity,
            amount0: isNoOpGovernance ? 0 : balance0 - (balance0 / 10),
            amount1: 0,
            recipient: recipient
        });

        // Then we repeat the two previous steps but this time for the below price positions
        modifyLiquidityParams[2] = ModifyLiquidityParams({
            lowerTick: lowerTick,
            upperTick: currentTick - poolKey.tickSpacing,
            liquidity: _roundDown(isNoOpGovernance ? belowPriceLiquidity : belowPriceLiquidity / 10),
            amount0: 0,
            amount1: isNoOpGovernance ? balance1 : balance1 / 10,
            recipient: address(this)
        });

        modifyLiquidityParams[3] = ModifyLiquidityParams({
            lowerTick: lowerTick,
            upperTick: currentTick - poolKey.tickSpacing,
            liquidity: _roundDown(isNoOpGovernance ? 0 : belowPriceLiquidity - (belowPriceLiquidity / 10)),
            amount0: 0,
            amount1: isNoOpGovernance ? 0 : balance1 - (balance1 / 10),
            recipient: recipient
        });

        // Check if some of the positions have <= 1 liquidity, skipping them will avoid rounding issues
        uint8 positionsToMint;

        for (uint256 i; i != 4; ++i) {
            if (modifyLiquidityParams[i].liquidity > 2) {
                ++positionsToMint;
            }
        }

        // We need to mint `positionsToMint` positions then call `SETTLE_PAIR` (and `SWEEP` if we're using ETH)
        uint8 length = positionsToMint + 1 + (token0 == address(0) ? 1 : 0);
        bytes[] memory params = new bytes[](length);
        bytes memory actions = new bytes(length);

        uint256 paramsIndex;

        // Let's copy the required positions to the params array, we also use this loop to set the action type
        for (uint256 i; i != 4; ++i) {
            if (modifyLiquidityParams[i].liquidity > 1) {
                params[paramsIndex] = abi.encode(
                    poolKey,
                    modifyLiquidityParams[i].lowerTick,
                    modifyLiquidityParams[i].upperTick,
                    modifyLiquidityParams[i].liquidity,
                    modifyLiquidityParams[i].amount0,
                    modifyLiquidityParams[i].amount1,
                    modifyLiquidityParams[i].recipient,
                    new bytes(0)
                );
                actions[paramsIndex] = bytes1(uint8(Actions.MINT_POSITION));
                unchecked {
                    ++paramsIndex;
                }
            }
        }

        // We add the `SETTLE_PAIR` action, if `SWEEP` is needed, it will be added at the end
        actions[positionsToMint] = bytes1(uint8(Actions.SETTLE_PAIR));

        // Parameters for the `SETTLE` action
        params[positionsToMint] = abi.encode(poolKey.currency0, poolKey.currency1);

        if (token0 == address(0)) {
            actions[length - 1] = bytes1(uint8(Actions.SWEEP));
            // Parameters for the `SWEEP` action
            params[length - 1] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
        } else {
            ERC20(token0).approve(address(positionManager.permit2()), balance0);
            positionManager.permit2().approve(token0, address(positionManager), uint160(balance0), type(uint48).max);
        }

        ERC20(token1).approve(address(positionManager.permit2()), balance1);
        positionManager.permit2().approve(token1, address(positionManager), uint160(balance1), type(uint48).max);

        uint256 nextTokenId = positionManager.nextTokenId();

        positionManager.modifyLiquidities{ value: token0 == address(0) ? balance0 : 0 }(
            abi.encode(abi.encodePacked(actions), params), block.timestamp
        );

        uint256 lastTokenId = positionManager.nextTokenId();

        for (; nextTokenId != lastTokenId; ++nextTokenId) {
            if (positionManager.ownerOf(nextTokenId) == address(this)) {
                positionManager.safeTransferFrom(
                    address(this),
                    address(locker),
                    nextTokenId,
                    abi.encode(recipient, assetData.lockDuration, assetData.beneficiaries)
                );
            }
        }

        // Transfer any remaining dust
        // For no-op governance, send dust to the protocol locker instead of dead address
        address dustRecipient = isNoOpGovernance ? address(locker) : recipient;
        if (poolKey.currency0.balanceOfSelf() > 0) {
            poolKey.currency0.transfer(dustRecipient, poolKey.currency0.balanceOfSelf());
        }
        if (poolKey.currency1.balanceOfSelf() > 0) {
            poolKey.currency1.transfer(dustRecipient, poolKey.currency1.balanceOfSelf());
        }

        emit Migrate(poolKey.toId(), sqrtPriceX96, lowerTick, upperTick, liquidity, balance0, balance1);
    }
}
