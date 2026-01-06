// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Quoter } from "@quoter/Quoter.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { RehypeDopplerHook, EPSILON, MAX_REBALANCE_ITERATIONS } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { SwapSimulation } from "src/types/RehypeTypes.sol";

/// @title RehypeDopplerHookHarness
/// @notice Test harness that exposes internal functions for unit testing
/// @dev Uses Option B from spec: copies functions with quoter parameter to work around immutable quoter
contract RehypeDopplerHookHarness is RehypeDopplerHook {
    constructor(address initializer, IPoolManager poolManager_) RehypeDopplerHook(initializer, poolManager_) { }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EXPOSED PURE FUNCTIONS (Direct access - no quoter needed)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Expose _calculateExcess for testing
    /// @param fees0 Available fees in currency0
    /// @param fees1 Available fees in currency1
    /// @param sqrtPriceX96 Current square root price of the pool
    /// @return excess0 Excess amount in currency0
    /// @return excess1 Excess amount in currency1
    function exposed_calculateExcess(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) external pure returns (uint256 excess0, uint256 excess1) {
        return _calculateExcess(fees0, fees1, sqrtPriceX96);
    }

    /// @notice Expose _score for testing
    /// @param excess0 First amount
    /// @param excess1 Second amount
    /// @return Greater amount (max of the two)
    function exposed_score(uint256 excess0, uint256 excess1) external pure returns (uint256) {
        return _score(excess0, excess1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EXPOSED FUNCTIONS WITH QUOTER OVERRIDE
    // These are copies of the internal functions that accept a quoter parameter
    // to allow testing with MockQuoter
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Expose _simulateSwap for testing with a custom quoter
    /// @dev Copy of _simulateSwap that accepts quoter parameter instead of using immutable
    /// @param q Quoter to use for simulation
    /// @param key Uniswap V4 pool key
    /// @param zeroForOne Direction of the swap
    /// @param guess Amount to swap in
    /// @param fees0 Available fees in currency0
    /// @param fees1 Available fees in currency1
    /// @return simulation Result of the swap simulation
    function exposed_simulateSwapWithQuoter(
        Quoter q,
        PoolKey memory key,
        bool zeroForOne,
        uint256 guess,
        uint256 fees0,
        uint256 fees1
    ) external view returns (SwapSimulation memory simulation) {
        if (guess == 0) return simulation;
        if (zeroForOne && guess > fees0) return simulation;
        if (!zeroForOne && guess > fees1) return simulation;

        try q.quoteSingle(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(guess),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        ) returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32) {
            if (zeroForOne) {
                if (amount0 >= 0 || amount1 <= 0) return simulation;
                uint256 amountIn = uint256(-amount0);
                if (amountIn > fees0) return simulation;
                uint256 amountOut = uint256(amount1);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 - amountIn;
                simulation.fees1 = fees1 + amountOut;
            } else {
                if (amount1 >= 0 || amount0 <= 0) return simulation;
                uint256 amountIn = uint256(-amount1);
                if (amountIn > fees1) return simulation;
                uint256 amountOut = uint256(amount0);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 + amountOut;
                simulation.fees1 = fees1 - amountIn;
            }

            simulation.sqrtPriceX96 = sqrtPriceAfterX96;
            (simulation.excess0, simulation.excess1) =
                _calculateExcess(simulation.fees0, simulation.fees1, sqrtPriceAfterX96);
        } catch {
            return simulation;
        }
    }

    /// @notice Expose _rebalanceFees for testing with a custom quoter
    /// @dev Copy of _rebalanceFees that uses exposed_simulateSwapWithQuoter
    /// @param q Quoter to use for simulation
    /// @param key Uniswap V4 pool key
    /// @param lpAmount0 Available amount in currency0
    /// @param lpAmount1 Available amount in currency1
    /// @param sqrtPriceX96 Current square root price of the pool
    /// @return shouldSwap Whether a swap should be executed
    /// @return zeroForOne Direction of the swap
    /// @return amountIn Amount to swap in
    /// @return amountOut Amount to receive from the swap
    /// @return newSqrtPriceX96 New square root price after the swap
    function exposed_rebalanceFeesWithQuoter(
        Quoter q,
        PoolKey memory key,
        uint256 lpAmount0,
        uint256 lpAmount1,
        uint160 sqrtPriceX96
    )
        external
        view
        returns (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 newSqrtPriceX96)
    {
        (uint256 excess0, uint256 excess1) = _calculateExcess(lpAmount0, lpAmount1, sqrtPriceX96);

        if (excess0 <= EPSILON && excess1 <= EPSILON) {
            return (false, false, 0, 0, sqrtPriceX96);
        }

        zeroForOne = excess0 >= excess1;
        uint256 high = zeroForOne ? excess0 : excess1;
        uint256 low;
        SwapSimulation memory best;

        for (uint256 i; i < MAX_REBALANCE_ITERATIONS && high > 0; ++i) {
            uint256 guess = (low + high) / 2;
            if (guess == 0) guess = 1;

            SwapSimulation memory sim = _simulateSwapWithQuoter(q, key, zeroForOne, guess, lpAmount0, lpAmount1);
            if (!sim.success) {
                if (high == 0 || high == 1) {
                    break;
                }
                high = guess > 0 ? guess - 1 : 0;
                continue;
            }

            if (!best.success || _score(sim.excess0, sim.excess1) < _score(best.excess0, best.excess1)) {
                best = sim;
            }

            if (sim.excess0 <= EPSILON && sim.excess1 <= EPSILON) {
                return (true, zeroForOne, sim.amountIn, sim.amountOut, sim.sqrtPriceX96);
            }

            if (zeroForOne) {
                if (sim.excess1 > EPSILON) {
                    if (guess <= 1) break;
                    high = guess - 1;
                } else {
                    if (low == guess) {
                        if (high <= guess + 1) break;
                    } else {
                        low = guess;
                    }
                }
            } else {
                if (sim.excess0 > EPSILON) {
                    if (guess <= 1) break;
                    high = guess - 1;
                } else {
                    if (low == guess) {
                        if (high <= guess + 1) break;
                    } else {
                        low = guess;
                    }
                }
            }
        }

        if (best.success) {
            return (true, zeroForOne, best.amountIn, best.amountOut, best.sqrtPriceX96);
        }

        return (false, zeroForOne, 0, 0, sqrtPriceX96);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPER - Copy of _simulateSwap with quoter parameter
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Internal version used by exposed_rebalanceFeesWithQuoter
    function _simulateSwapWithQuoter(
        Quoter q,
        PoolKey memory key,
        bool zeroForOne,
        uint256 guess,
        uint256 fees0,
        uint256 fees1
    ) internal view returns (SwapSimulation memory simulation) {
        if (guess == 0) return simulation;
        if (zeroForOne && guess > fees0) return simulation;
        if (!zeroForOne && guess > fees1) return simulation;

        try q.quoteSingle(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(guess),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        ) returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32) {
            if (zeroForOne) {
                if (amount0 >= 0 || amount1 <= 0) return simulation;
                uint256 amountIn = uint256(-amount0);
                if (amountIn > fees0) return simulation;
                uint256 amountOut = uint256(amount1);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 - amountIn;
                simulation.fees1 = fees1 + amountOut;
            } else {
                if (amount1 >= 0 || amount0 <= 0) return simulation;
                uint256 amountIn = uint256(-amount1);
                if (amountIn > fees1) return simulation;
                uint256 amountOut = uint256(amount0);
                simulation.success = true;
                simulation.amountIn = amountIn;
                simulation.amountOut = amountOut;
                simulation.fees0 = fees0 + amountOut;
                simulation.fees1 = fees1 - amountIn;
            }

            simulation.sqrtPriceX96 = sqrtPriceAfterX96;
            (simulation.excess0, simulation.excess1) =
                _calculateExcess(simulation.fees0, simulation.fees1, sqrtPriceAfterX96);
        } catch {
            return simulation;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DIRECT EXPOSED FUNCTIONS (Using real quoter - for integration-style tests)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Expose _rebalanceFees using the real quoter
    /// @dev Use this for integration-style tests with a real pool
    function exposed_rebalanceFees(
        PoolKey memory key,
        uint256 lpAmount0,
        uint256 lpAmount1,
        uint160 sqrtPriceX96
    )
        external
        view
        returns (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 newSqrtPriceX96)
    {
        return _rebalanceFees(key, lpAmount0, lpAmount1, sqrtPriceX96);
    }

    /// @notice Expose _simulateSwap using the real quoter
    /// @dev Use this for integration-style tests with a real pool
    function exposed_simulateSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 guess,
        uint256 fees0,
        uint256 fees1
    ) external view returns (SwapSimulation memory) {
        return _simulateSwap(key, zeroForOne, guess, fees0, fees1);
    }
}
