// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { Airlock } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ProceedsSplitter, SplitConfiguration } from "src/base/ProceedsSplitter.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES, storeBeneficiaries } from "src/types/BeneficiaryData.sol";
import { DEAD_ADDRESS, EMPTY_ADDRESS } from "src/types/Constants.sol";
import { Position } from "src/types/Position.sol";

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
 * @title Uniswap V4 Migrator Split
 * @author Whetstone Research
 * @notice Module contract to migrate liquidity from a Doppler Dutch auction pool to a
 * regular Uniswap V4 pool
 */
contract UniswapV4MigratorSplit is ILiquidityMigrator, ImmutableAirlock, ProceedsSplitter {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the Uniswap V4 Position Manager contract
    PositionManager public immutable positionManager;

    /// @notice Address of the Streamable Fees Locker
    StreamableFeesLockerV2 public immutable locker;

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
        StreamableFeesLockerV2 locker_,
        IHooks migratorHook_,
        TopUpDistributor topUpDistributor
    ) ImmutableAirlock(airlock_) ProceedsSplitter(topUpDistributor) {
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
        (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            address proceedsRecipient,
            uint256 proceedsShare
        ) = abi.decode(liquidityMigratorData, (uint24, int24, uint32, BeneficiaryData[], address, uint256));

        isTickSpacingValid(tickSpacing);
        LPFeeLibrary.validate(fee);
        storeBeneficiaries(
            PoolId.wrap(0), beneficiaries, Airlock(airlock).owner(), MIN_PROTOCOL_OWNER_SHARES, storeBeneficiary
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

        if (proceedsRecipient != address(0)) {
            _setSplit(
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                SplitConfiguration({ recipient: proceedsRecipient, isToken0: asset < numeraire, share: proceedsShare })
            );
        }

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

        if (splitConfigurationOf[token0][token1].recipient != address(0)) {
            (balance0, balance1) = _distributeSplit(token0, token1, balance0, balance1);
        }

        int24 lowerTick = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(poolKey.tickSpacing);

        // A pool can be initialized at any tick but we want to make sure our current tick is
        // aligned with the tick spacing when we'll add liquidity
        currentTick = currentTick / poolKey.tickSpacing * poolKey.tickSpacing;

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        // We're adding liquidity to two single-sided positions instead of a full range position, this is to ensure
        // we're using as much tokens as possible and will result in more liquidity being added to the pool. Note that
        // we decremented the balances by `1` (if possible) to avoid rounding issues during liquidity computation
        uint160 sqrtPriceAtLowerTick = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceAtBelowUpperTick = TickMath.getSqrtPriceAtTick(currentTick - poolKey.tickSpacing);
        uint160 sqrtPriceAtAboveLowerTick = TickMath.getSqrtPriceAtTick(currentTick + poolKey.tickSpacing);
        uint160 sqrtPriceAtUpperTick = TickMath.getSqrtPriceAtTick(upperTick);

        uint128 belowPriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAtLowerTick,
            sqrtPriceAtBelowUpperTick,
            0,
            balance1 == 0 ? 0 : uint128(balance1) - 1
        );

        uint128 abovePriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAtAboveLowerTick,
            sqrtPriceAtUpperTick,
            balance0 == 0 ? 0 : uint128(balance0) - 1,
            0
        );

        // Total liquidity provided into the pool
        liquidity = uint256(belowPriceLiquidity) + uint256(abovePriceLiquidity);
        require(liquidity > 0, ZeroLiquidity());

        (
            Position[] memory lockerPositions,
            uint8 lockerPositionsToMint,
            uint256 lockerBalance0,
            uint256 lockerBalance1,
            uint128 recipientBelowPriceLiquidity,
            uint128 recipientAbovePriceLiquidity
        ) = _computeLockerPositions(
            poolKey.tickSpacing,
            currentTick,
            lowerTick,
            upperTick,
            isNoOpGovernance,
            belowPriceLiquidity,
            abovePriceLiquidity
        );

        uint256 recipientBalance0 = balance0 - lockerBalance0;
        uint256 recipientBalance1 = balance1 - lockerBalance1;

        // We might mint up to 2 recipient positions, let's compute the liquidity for each of them and see if it's > 0
        uint8 recipientPositionsToMint = (recipientBelowPriceLiquidity > 0 ? 1 : 0) + (recipientAbovePriceLiquidity > 0 ? 1 : 0);
        bytes[] memory temporaryParams = new bytes[](recipientPositionsToMint);
        uint8 recipientPositionIndex;

        if (recipientBelowPriceLiquidity > 0) {
            temporaryParams[recipientPositionIndex++] = abi.encode(
                poolKey,
                lowerTick,
                currentTick - poolKey.tickSpacing,
                recipientBelowPriceLiquidity,
                0,
                recipientBalance1,
                recipient,
                new bytes(0)
            );
        }

        if (recipientAbovePriceLiquidity > 0) {
            temporaryParams[recipientPositionIndex++] = abi.encode(
                poolKey,
                currentTick + poolKey.tickSpacing,
                upperTick,
                recipientAbovePriceLiquidity,
                recipientBalance0,
                0,
                recipient,
                new bytes(0)
            );
        }

        _mintRecipientPositions(
            token0, poolKey, temporaryParams, recipientPositionsToMint, recipientBalance0, recipientBalance1
        );

        _lockProtocolPositions(
            poolKey,
            assetData.lockDuration,
            recipient,
            assetData.beneficiaries,
            lockerPositions,
            lockerPositionsToMint,
            lockerBalance0,
            lockerBalance1
        );

        // Transfer any remaining dust, either to the governance or the Airlock owner
        address dustRecipient = isNoOpGovernance ? airlock.owner() : recipient;
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

    function _mintRecipientPositions(
        address token0,
        PoolKey memory poolKey,
        bytes[] memory temporaryParams,
        uint8 recipientPositionsToMint,
        uint256 recipientBalance0,
        uint256 recipientBalance1
    ) private {
        if (recipientPositionsToMint == 0) return;

        uint8 length = recipientPositionsToMint + 1 + (token0 == address(0) ? 1 : 0);
        bytes[] memory params = new bytes[](length);
        bytes memory actions = new bytes(length);

        for (uint256 i; i < recipientPositionsToMint; ++i) {
            params[i] = temporaryParams[i];
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
        }

        actions[recipientPositionsToMint] = bytes1(uint8(Actions.SETTLE_PAIR));
        params[recipientPositionsToMint] = abi.encode(poolKey.currency0, poolKey.currency1);

        if (token0 == address(0)) {
            actions[length - 1] = bytes1(uint8(Actions.SWEEP));
            params[length - 1] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
        } else {
            ERC20(token0).approve(address(positionManager.permit2()), recipientBalance0);
            positionManager.permit2().approve(token0, address(positionManager), uint160(recipientBalance0), type(uint48).max);
        }

        ERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager.permit2()), recipientBalance1);
        positionManager.permit2().approve(
            Currency.unwrap(poolKey.currency1), address(positionManager), uint160(recipientBalance1), type(uint48).max
        );

        positionManager.modifyLiquidities{ value: token0 == address(0) ? recipientBalance0 : 0 }(
            abi.encode(abi.encodePacked(actions), params), block.timestamp
        );
    }

    function _lockProtocolPositions(
        PoolKey memory poolKey,
        uint32 lockDuration,
        address recipient,
        BeneficiaryData[] memory beneficiaries,
        Position[] memory lockerPositions,
        uint8 lockerPositionsToMint,
        uint256 lockerBalance0,
        uint256 lockerBalance1
    ) private {
        if (lockerPositionsToMint == 0) return;

        poolKey.currency0.transfer(address(locker), lockerBalance0);
        poolKey.currency1.transfer(address(locker), lockerBalance1);
        locker.lock(poolKey, lockDuration, recipient, beneficiaries, lockerPositions);
    }

    function _computeLockerPositions(
        int24 tickSpacing,
        int24 currentTick,
        int24 lowerTick,
        int24 upperTick,
        bool isNoOpGovernance,
        uint128 belowPriceLiquidity,
        uint128 abovePriceLiquidity
    ) private pure returns (
        Position[] memory lockerPositions,
        uint8 lockerPositionsToMint,
        uint256 lockerBalance0,
        uint256 lockerBalance1,
        uint128 recipientBelowPriceLiquidity,
        uint128 recipientAbovePriceLiquidity
    ) {
        uint128 protocolLockerBelowPriceLiquidity = isNoOpGovernance ? belowPriceLiquidity : belowPriceLiquidity / 10;
        uint128 protocolLockerAbovePriceLiquidity = isNoOpGovernance ? abovePriceLiquidity : abovePriceLiquidity / 10;
        recipientBelowPriceLiquidity = isNoOpGovernance ? 0 : belowPriceLiquidity - protocolLockerBelowPriceLiquidity;
        recipientAbovePriceLiquidity = isNoOpGovernance ? 0 : abovePriceLiquidity - protocolLockerAbovePriceLiquidity;

        lockerPositionsToMint = (protocolLockerBelowPriceLiquidity > 0 ? 1 : 0) + (protocolLockerAbovePriceLiquidity > 0 ? 1 : 0);
        lockerPositions = new Position[](lockerPositionsToMint);

        uint8 lockerPositionIndex;

        if (protocolLockerBelowPriceLiquidity > 0) {
            lockerPositions[lockerPositionIndex++] = Position({
                tickLower: lowerTick,
                tickUpper: currentTick - tickSpacing,
                liquidity: protocolLockerBelowPriceLiquidity,
                salt: bytes32(0)
            });

            lockerBalance1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(lowerTick),
                TickMath.getSqrtPriceAtTick(currentTick - tickSpacing),
                protocolLockerBelowPriceLiquidity,
                true
            );
        }

        if (protocolLockerAbovePriceLiquidity > 0) {
            lockerPositions[lockerPositionIndex] = Position({
                tickLower: currentTick + tickSpacing,
                tickUpper: upperTick,
                liquidity: protocolLockerAbovePriceLiquidity,
                salt: bytes32(0)
            });

            lockerBalance0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(currentTick + tickSpacing),
                TickMath.getSqrtPriceAtTick(upperTick),
                protocolLockerAbovePriceLiquidity,
                true
            );
        }
    }
}
