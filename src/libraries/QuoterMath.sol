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
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { PoolTickBitmap } from "./PoolTickBitmap.sol";

/// @title QuoterMath
/// @notice View-only swap simulation for Uniswap V4
/// @dev Adapted from Jun1on/view-quoter-v4 with protocol fee and dynamic LP fee support
library QuoterMath {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Slot0Library for Slot0;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for *;

    struct Slot0Struct {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // tick spacing
        int24 tickSpacing;
        // fee of pool (cannot use poolkey)
        uint24 lpFee;
        // protocol fee
        uint24 protocolFee;
    }

    // used for packing under the stack limit
    struct QuoteParams {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    function fillSlot0(IPoolManager poolManager, PoolKey memory poolKey)
        private
        view
        returns (Slot0Struct memory slot0)
    {
        (slot0.sqrtPriceX96, slot0.tick, slot0.protocolFee, slot0.lpFee) = poolManager.getSlot0(poolKey.toId());
        slot0.tickSpacing = poolKey.tickSpacing;
        return slot0;
    }

    /// @notice Utility function called by the quote functions to
    /// calculate the amounts in/out for a hookless v4 swap
    /// @param poolManager the Uniswap v4 pool manager
    /// @param poolKey The poolKey identifying the pool traded against
    /// @param swapParams The parameters used for the swap
    /// @return amount0 the amount of token0 sent in or out of the pool
    /// @return amount1 the amount of token1 sent in or out of the pool
    /// @return sqrtPriceAfterX96 the price of the pool after the swap
    /// @return initializedTicksCrossed the number of initialized ticks LOADED IN
    function quote(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    )
        internal
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        Slot0Struct memory slot0 = fillSlot0(poolManager, poolKey);

        QuoteParams memory quoteParams = QuoteParams(
            swapParams.zeroForOne, swapParams.amountSpecified < 0, slot0.lpFee, swapParams.sqrtPriceLimitX96
        );
        initializedTicksCrossed = 1;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: -swapParams.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0.sqrtPriceX96,
            tick: slot0.tick,
            feeGrowthGlobalX128: 0, // meaningless for quote
            protocolFee: slot0.protocolFee,
            liquidity: poolManager.getLiquidity(poolKey.toId())
        });

        uint256 protocolFee =
            swapParams.zeroForOne ? slot0.protocolFee.getZeroForOneFee() : slot0.protocolFee.getOneForZeroFee();

        uint24 swapFee = protocolFee == 0 ? slot0.lpFee : uint16(protocolFee).calculateSwapFee(slot0.lpFee);

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != quoteParams.sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = PoolTickBitmap.nextInitializedTickWithinOneWord(
                poolManager, poolKey.toId(), slot0.tickSpacing, state.tick, quoteParams.zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    quoteParams.zeroForOne
                        ? step.sqrtPriceNextX96 < quoteParams.sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > quoteParams.sqrtPriceLimitX96
                ) ? quoteParams.sqrtPriceLimitX96 : step.sqrtPriceNextX96,
                state.liquidity,
                -state.amountSpecifiedRemaining,
                swapFee
            );

            if (quoteParams.exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated + step.amountOut.toInt256();
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (, int128 liquidityNet,,) = poolManager.getTickInfo(poolKey.toId(), step.tickNext);

                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (quoteParams.zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);

                    initializedTicksCrossed++;
                }

                state.tick = quoteParams.zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }

            (amount0, amount1) = quoteParams.zeroForOne == quoteParams.exactInput
                ? (state.amountSpecifiedRemaining + swapParams.amountSpecified, state.amountCalculated)
                : (state.amountCalculated, state.amountSpecifiedRemaining + swapParams.amountSpecified);

            sqrtPriceAfterX96 = state.sqrtPriceX96;
        }
    }
}
