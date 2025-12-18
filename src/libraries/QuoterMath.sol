// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import { SwapMath } from "@v4-core/libraries/SwapMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { LiquidityMath } from "@v4-core/libraries/LiquidityMath.sol";
import { SafeCast } from "@v4-core/libraries/SafeCast.sol";
import { Slot0, Slot0Library } from "@v4-core/types/Slot0.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolTickBitmap } from "./PoolTickBitmap.sol";

/// @title QuoterMath
/// @notice View-only swap simulation for Uniswap V4
/// @dev Adapted from Jun1on/view-quoter-v4
library QuoterMath {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Slot0Library for Slot0;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Slot0Struct {
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickSpacing;
    }

    struct QuoteParams {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function fillSlot0(IPoolManager poolManager, PoolKey memory poolKey)
        private
        view
        returns (Slot0Struct memory slot0)
    {
        (slot0.sqrtPriceX96, slot0.tick,,) = poolManager.getSlot0(poolKey.toId());
        slot0.tickSpacing = poolKey.tickSpacing;
        return slot0;
    }

    /// @notice Quote a swap without executing it
    /// @param poolManager The pool manager
    /// @param poolKey The pool to quote against
    /// @param swapParams The swap parameters
    /// @return amount0 Token0 delta
    /// @return amount1 Token1 delta
    /// @return sqrtPriceAfterX96 Price after swap
    /// @return initializedTicksCrossed Number of initialized ticks crossed
    function quote(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    )
        internal
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        QuoteParams memory quoteParams = QuoteParams(
            swapParams.zeroForOne,
            swapParams.amountSpecified < 0,
            poolKey.fee,
            swapParams.sqrtPriceLimitX96
        );
        initializedTicksCrossed = 1;

        Slot0Struct memory slot0 = fillSlot0(poolManager, poolKey);

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: -swapParams.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0.sqrtPriceX96,
            tick: slot0.tick,
            liquidity: poolManager.getLiquidity(poolKey.toId())
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != quoteParams.sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = PoolTickBitmap.nextInitializedTickWithinOneWord(
                poolManager, poolKey.toId(), slot0.tickSpacing, state.tick, quoteParams.zeroForOne
            );

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    quoteParams.zeroForOne
                        ? step.sqrtPriceNextX96 < quoteParams.sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > quoteParams.sqrtPriceLimitX96
                ) ? quoteParams.sqrtPriceLimitX96 : step.sqrtPriceNextX96,
                state.liquidity,
                -state.amountSpecifiedRemaining,
                quoteParams.fee
            );

            if (quoteParams.exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated + step.amountOut.toInt256();
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    (, int128 liquidityNet,,) = poolManager.getTickInfo(poolKey.toId(), step.tickNext);

                    if (quoteParams.zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);

                    initializedTicksCrossed++;
                }

                state.tick = quoteParams.zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }

            (amount0, amount1) = quoteParams.zeroForOne == quoteParams.exactInput
                ? (state.amountSpecifiedRemaining + swapParams.amountSpecified, state.amountCalculated)
                : (state.amountCalculated, state.amountSpecifiedRemaining + swapParams.amountSpecified);

            sqrtPriceAfterX96 = state.sqrtPriceX96;
        }
    }
}
