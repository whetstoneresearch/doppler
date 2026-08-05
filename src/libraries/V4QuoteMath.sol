// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Quoter } from "@quoter/Quoter.sol";

/// @notice Quote + inversion helpers for Uniswap v4 concentrated liquidity.
/// @dev This is intentionally a "source of truth" for:
/// - Normalizing `Quoter.quoteSingle` signed amounts into (amountInUsed, amountOut)
/// - Finding an amountIn that yields amountOut <= budget (output-budgeted execution)
///
/// Why inversion is hard:
/// - With concentrated liquidity, amountOut(amountIn) is monotonic but not linear.
/// - Closed-form inversion is not practical on-chain; the safest approach is quoting + search.
library V4QuoteMath {
    uint256 internal constant DEFAULT_MAX_ITERATIONS = 15;

    function quoteExactIn(Quoter quoter, PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 amountOut, uint256 amountInUsed)
    {
        if (amountIn == 0) return (false, 0, 0);

        // We intentionally do not wrap this in try/catch.
        // In this codebase, `@quoter/Quoter.sol` maps to the view-quoter implementation
        // (lib/view-quoter-v4) which is expected to return zero values on non-quotable swaps
        // rather than reverting.
        (int256 amount0, int256 amount1,,) = quoter.quoteSingle(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        if (zeroForOne) {
            if (amount0 >= 0 || amount1 <= 0) return (false, 0, 0);
            amountInUsed = uint256(-amount0);
            amountOut = uint256(amount1);
        } else {
            if (amount1 >= 0 || amount0 <= 0) return (false, 0, 0);
            amountInUsed = uint256(-amount1);
            amountOut = uint256(amount0);
        }

        if (amountInUsed == 0 || amountOut == 0 || amountInUsed > amountIn) return (false, 0, 0);
        ok = true;
    }

    /// @notice Find the largest `amountIn` such that the quoted output is <= `outBudget`.
    /// @dev Bounded binary search. This is the robust way to handle concentrated liquidity slippage.
    function findAmountInForOutBudget(
        Quoter quoter,
        PoolKey memory key,
        bool zeroForOne,
        uint256 outBudget,
        uint256 maxAmountIn,
        uint256 maxIterations
    ) internal view returns (uint256 amountIn, uint256 expectedOut) {
        if (outBudget == 0 || maxAmountIn == 0) return (0, 0);
        if (maxIterations == 0) maxIterations = DEFAULT_MAX_ITERATIONS;

        uint256 low;
        uint256 high = maxAmountIn;

        for (uint256 i; i < maxIterations && high > 0; i++) {
            uint256 guess = (low + high) / 2;
            if (guess == 0) guess = 1;

            (bool ok, uint256 out,) = quoteExactIn(quoter, key, zeroForOne, guess);
            if (!ok || out == 0) {
                if (high <= 1) break;
                high = guess > 0 ? guess - 1 : 0;
                continue;
            }

            if (out > outBudget) {
                if (guess <= 1) break;
                high = guess - 1;
                continue;
            }

            // out <= budget is feasible
            amountIn = guess;
            expectedOut = out;
            if (out == outBudget) break;
            if (low == guess) {
                if (high <= guess + 1) break;
            } else {
                low = guess;
            }
        }
    }
}
