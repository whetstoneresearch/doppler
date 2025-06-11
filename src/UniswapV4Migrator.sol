// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData, StreamableFeesLocker } from "src/StreamableFeesLocker.sol";

/**
 * @notice Data to use for the migration
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param beneficiaries Array of beneficiaries used by the locker contract
 */
struct AssetData {
    PoolKey poolKey;
    BeneficiaryData[] beneficiaries;
}

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

    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    receive() external payable { }

    /**
     *
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager contract
     * @param positionManager_ Address of the Uniswap V4 Position Manager contract
     * @param locker_ Address of the Streamable Fees Locker contract
     */
    constructor(
        address airlock_,
        address poolManager_,
        address payable positionManager_,
        StreamableFeesLocker locker_
    ) ImmutableAirlock(airlock_) {
        poolManager = IPoolManager(poolManager_);
        positionManager = PositionManager(positionManager_);
        locker = locker_;
    }

    /// @inheritdoc ILiquidityMigrator
    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        (uint24 fee, int24 tickSpacing, BeneficiaryData[] memory data) =
            abi.decode(liquidityMigratorData, (uint24, int24, BeneficiaryData[]));

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(address(0)),
            fee: fee,
            tickSpacing: tickSpacing
        });

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] =
            AssetData({ poolKey: poolKey, beneficiaries: data });

        return address(0);
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

        // Let's check if the pool was initialized
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (currentSqrtPriceX96 == 0) {
            IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);
        }

        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        uint256 balance0;
        bytes memory actions;
        bytes[] memory params;

        if (token0 == address(0)) {
            params = new bytes[](4);
            params[3] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
            balance0 = address(this).balance;
            actions = abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.SWEEP)
            );
        } else {
            params = new bytes[](3);
            balance0 = ERC20(token0).balanceOf(address(this));
            actions =
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        }

        int24 lowerTick =
            ((TickMath.MIN_TICK + 1) - poolKey.tickSpacing + 1) / poolKey.tickSpacing * poolKey.tickSpacing;
        int24 upperTick = (TickMath.MAX_TICK - 1) / poolKey.tickSpacing * poolKey.tickSpacing;

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(upperTick),
            uint128(balance0),
            uint128(balance1)
        );

        if (liquidity == 0) revert ZeroLiquidity();

        uint256 lockedLiquidity = liquidity / 10;
        uint256 timeLockLiquidity = liquidity - lockedLiquidity;

        // Liquidity for the protocol locker
        params[0] = abi.encode(
            poolKey,
            lowerTick,
            upperTick,
            uint128(lockedLiquidity),
            uint128(balance0) / 10,
            uint128(balance1) / 10,
            address(this),
            new bytes(0)
        );

        // Liquidity for the Timelock
        params[1] = abi.encode(
            poolKey,
            lowerTick,
            upperTick,
            uint128(timeLockLiquidity),
            uint128(balance0),
            uint128(balance1),
            recipient,
            new bytes(0)
        );

        params[2] = abi.encode(poolKey.currency0, poolKey.currency1);

        if (token0 != address(0)) {
            ERC20(token0).approve(address(positionManager.permit2()), balance0);
            positionManager.permit2().approve(token0, address(positionManager), uint160(balance0), type(uint48).max);
        }

        ERC20(token1).approve(address(positionManager.permit2()), balance1);
        positionManager.permit2().approve(token1, address(positionManager), uint160(balance1), type(uint48).max);

        positionManager.modifyLiquidities{ value: token0 == address(0) ? balance0 : 0 }(
            abi.encode(actions, params), block.timestamp
        );

        positionManager.safeTransferFrom(
            address(this),
            address(locker),
            positionManager.nextTokenId() - 2,
            abi.encode(recipient, assetData.beneficiaries)
        );

        if (poolKey.currency0.balanceOfSelf() > 0) {
            poolKey.currency0.transfer(recipient, poolKey.currency0.balanceOfSelf());
        }
        if (poolKey.currency1.balanceOfSelf() > 0) {
            poolKey.currency1.transfer(recipient, poolKey.currency1.balanceOfSelf());
        }
    }
}
