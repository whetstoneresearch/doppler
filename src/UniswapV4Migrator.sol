// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

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
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { BeneficiaryData, storeBeneficiaries, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { DEAD_ADDRESS, EMPTY_ADDRESS } from "src/types/Constants.sol";
import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
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

        isTickSpacingValid(tickSpacing);
        LPFeeLibrary.validate(fee);
        storeBeneficiaries(
            beneficiaries, Airlock(airlock).owner(), MIN_PROTOCOL_OWNER_SHARES, PoolId.wrap(0), storeBeneficiary
        );

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: migratorHook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] =
            AssetData({ poolKey: poolKey, lockDuration: lockDuration, beneficiaries: beneficiaries });

        return EMPTY_ADDRESS; // v4 pools are represented by their PoolKey, so we return an empty address
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

        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        uint256 balance0 = token0 == address(0) ? address(this).balance : ERC20(token0).balanceOf(address(this));

        int24 lowerTick = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(poolKey.tickSpacing);

        // A pool can be initialized at any tick but we want to make sure our current tick is
        // aligned with the tick spacing when we'll add liquidity
        currentTick = currentTick / poolKey.tickSpacing * poolKey.tickSpacing;

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        // We're adding liquidity to two single-sided positions instead of a full range position, this is to ensure
        // we're using as much tokens as possible and will result in more liquidity being added to the pool. Note that
        // we decremented the balances by `1` (if possible) to avoid rounding issues during liquidity computation
        uint160 belowPriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(currentTick - poolKey.tickSpacing),
            0,
            balance1 == 0 ? 0 : uint128(balance1) - 1
        );

        uint160 abovePriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(currentTick + poolKey.tickSpacing),
            TickMath.getSqrtPriceAtTick(upperTick),
            balance0 == 0 ? 0 : uint128(balance0) - 1,
            0
        );

        // Total liquidity provided into the pool
        liquidity = belowPriceLiquidity + abovePriceLiquidity;
        require(liquidity > 0, ZeroLiquidity());

        // We might mint up to 4 positions, let's compute the liquidity for each of them and see if it's > 0
        bytes[] memory temporaryParams = new bytes[](4);
        uint8 positionsToMint;

        uint256 protocolLockerBelowPriceLiquidity = isNoOpGovernance ? belowPriceLiquidity : belowPriceLiquidity / 10;

        if (protocolLockerBelowPriceLiquidity > 0) {
            temporaryParams[positionsToMint++] = abi.encode(
                poolKey,
                lowerTick,
                currentTick - poolKey.tickSpacing,
                protocolLockerBelowPriceLiquidity,
                0,
                balance1,
                address(this),
                new bytes(0)
            );
        }

        uint256 protocolLockerAbovePriceLiquidity = isNoOpGovernance ? abovePriceLiquidity : abovePriceLiquidity / 10;

        if (protocolLockerAbovePriceLiquidity > 0) {
            temporaryParams[positionsToMint++] = abi.encode(
                poolKey,
                currentTick + poolKey.tickSpacing,
                upperTick,
                protocolLockerAbovePriceLiquidity,
                balance0,
                0,
                address(this),
                new bytes(0)
            );
        }

        uint256 recipientBelowPriceLiquidity =
            isNoOpGovernance ? 0 : belowPriceLiquidity - protocolLockerBelowPriceLiquidity;

        if (recipientBelowPriceLiquidity > 0) {
            temporaryParams[positionsToMint++] = abi.encode(
                poolKey,
                lowerTick,
                currentTick - poolKey.tickSpacing,
                recipientBelowPriceLiquidity,
                0,
                balance1,
                recipient,
                new bytes(0)
            );
        }

        uint256 recipientAbovePriceLiquidity =
            isNoOpGovernance ? 0 : abovePriceLiquidity - protocolLockerAbovePriceLiquidity;

        if (recipientAbovePriceLiquidity > 0) {
            temporaryParams[positionsToMint++] = abi.encode(
                poolKey,
                currentTick + poolKey.tickSpacing,
                upperTick,
                recipientAbovePriceLiquidity,
                balance0,
                0,
                recipient,
                new bytes(0)
            );
        }

        // We need to mint `positionsToMint` positions then call `SETTLE_PAIR` and `SWEEP` if we're using ETH
        uint8 length = positionsToMint + 1 + (token0 == address(0) ? 1 : 0);
        bytes[] memory params = new bytes[](length);
        bytes memory actions = new bytes(length);

        for (uint256 i; i < positionsToMint; ++i) {
            params[i] = temporaryParams[i];
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
        }

        // We add the `SETTLE_PAIR` action, if `SWEEP` is needed, it will be added at the end
        actions[positionsToMint] = bytes1(uint8(Actions.SETTLE_PAIR));
        params[positionsToMint] = abi.encode(poolKey.currency0, poolKey.currency1);

        if (token0 == address(0)) {
            // Parameters for the `SWEEP` action
            actions[length - 1] = bytes1(uint8(Actions.SWEEP));
            params[length - 1] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
        } else {
            ERC20(token0).approve(address(positionManager.permit2()), balance0);
            positionManager.permit2().approve(token0, address(positionManager), uint160(balance0), type(uint48).max);
        }

        ERC20(token1).approve(address(positionManager.permit2()), balance1);
        positionManager.permit2().approve(token1, address(positionManager), uint160(balance1), type(uint48).max);

        // We're storing the tokenId of the first position we're going to mint
        uint256 nextTokenId = positionManager.nextTokenId();

        positionManager.modifyLiquidities{ value: token0 == address(0) ? balance0 : 0 }(
            abi.encode(abi.encodePacked(actions), params), block.timestamp
        );

        if (protocolLockerBelowPriceLiquidity > 0) {
            positionManager.safeTransferFrom(
                address(this),
                address(locker),
                nextTokenId, // Governance or not the first position is always for the locker
                abi.encode(recipient, assetData.lockDuration, assetData.beneficiaries)
            );

            nextTokenId++;
        }

        if (protocolLockerAbovePriceLiquidity > 0) {
            positionManager.safeTransferFrom(
                address(this),
                address(locker),
                nextTokenId, // Previously incremented if we minted a below price position for the protocol locker
                abi.encode(recipient, assetData.lockDuration, assetData.beneficiaries)
            );
        }

        // Transfer any remaining dust,
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

    /// @dev NoOp function to pass to `storeBeneficiaries()`, since we don't need to store the beneficiaries
    function storeBeneficiary(PoolId, BeneficiaryData memory) private pure { }
}
