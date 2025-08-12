// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "./PoolOperation.sol";

library miniV4Manager {
    using BalanceDeltaLibrary for BalanceDelta;

    uint8 constant MINT = 1;
    uint8 constant BURN = 2;
    uint8 constant COLLECT = 3;

    struct CallbackData {
        PoolKey poolKey;
        LpPosition[] positions;
        uint8 command;
    }

    struct LpPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint16 id;
    }

    struct ModifyLiquidityParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // how to modify the liquidity
        int256 liquidityDelta;
        // a value to set if you want unique liquidity positions at the same range
        bytes32 salt;
    }

    function lockAndMint(IPoolManager poolManager, PoolKey memory poolKey, LpPosition[] memory positions) internal {
        bytes memory data = abi.encode(CallbackData({ poolKey: poolKey, positions: positions, command: MINT }));

        IPoolManager(poolManager).unlock(data);
    }

    /// @notice Handles the callback from the pool manager.  Called by the initializer
    function handleCallback(IPoolManager poolManager, bytes memory data) internal returns (bytes memory) {
        CallbackData callback = abi.decode(data);

        uint8 command = callback.command;

        int128 amount0;
        int128 amount1;
        int128 fees0;
        int128 fees1;
        if (command == MINT) {
            (amount0, amount1) = handleMint(poolManager, poolcallback.positions);
            handleSettle(amount0 + fees0, amount1 + fees1);
            return bytes("");
        } else if (command == BURN) {
            (amount0, amount1, fees0, fees1) = handleBurn(poolManager, callback.positions);
            handleSettle(amount0 + fees0, amount1 + fees1);
            return bytes("");
        } else if (command == COLLECT) {
            (fees0, fees1) = handleCollect(poolManager, callback.positions);
            handleSettle(amount0 + fees0, amount1 + fees1);
            return bytes("");
        }
        revert InvalidCallbackId(command);
    }

    function handleMint(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        LpPosition[] memory positions
    ) internal returns (int128 amount0, int128 amount1) {
        ModifyLiquidityParams memory params;
        uint256 numPositions = positions.length;

        for (uint256 i; i < numPositions; i++) {
            params = ModifyLiquidityParams({
                tickLower: positions[i].tickLower,
                tickUpper: positions[i].tickUpper,
                liquidityDelta: positions[i].liquidity,
                salt: 0
            });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, "");

            amount0 += delta.amount0();
            amount1 += delta.amount1();
        }
    }

    function handleBurn(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        LpPosition[] memory positions
    ) internal returns (int128 amount0, int128 amount1, int128 fees0, int128 fees1) {
        ModifyLiquidityParams memory params;

        for (uint256 i; i < positions.length; i++) {
            params = ModifyLiquidityParams({
                tickLower: positions[i].tickLower,
                tickUpper: positions[i].tickUpper,
                liquidityDelta: -1 * positions[i].liquidity,
                salt: 0
            });

            (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(poolKey, params, "");

            amount0 += liquidityDelta.amount0();
            amount1 += liquidityDelta.amount1();
            fees0 += feesAccrued.amount0();
            fees1 += feesAccrued.amount1();
        }
    }

    function handleCollect(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        LpPosition[] memory positions
    ) internal returns (int128 fees0, int128 fees1) {
        ModifyLiquidityParams memory params;

        for (uint256 i; i < positions.length; i++) {
            params = ModifyLiquidityParams({
                tickLower: positions[i].tickLower,
                tickUpper: positions[i].tickUpper,
                liquidityDelta: 0,
                salt: 0
            });

            (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(poolKey, params, "");

            fees0 += feesAccrued.amount0();
            fees1 += feesAccrued.amount1();
        }
    }

    function handleSettle(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint256 expectedAmount0,
        uint256 expectedAmount1
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (expectedAmount0 > 0) {
            poolManager.take(poolKey.currency0, address(this), expectedAmount0);
        }

        if (expectedAmount1 > 0) {
            poolManager.take(poolKey.currency1, address(this), expectedAmount1);
        }

        if (expectedAmount0 < 0) {
            poolManager.sync(poolKey.currency0);
            poolKey.currency0.transfer(address(poolManager), expectedAmount0);
            poolManager.settle();
        }

        if (expectedAmount1 < 0) {
            poolManager.sync(poolKey.currency1);
            poolKey.currency1.transfer(address(poolManager), expectedAmount1);
            poolManager.settle();
        }
    }
}
