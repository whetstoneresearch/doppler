// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

/// @notice Thrown when the tick is not aligned with the tick spacing
error TickNotAligned(int24 tick);

/// @notice Thrown when the tick range is misordered
error TickRangeMisordered(int24 tickLower, int24 tickUpper);

/**
 * @notice Aligns a given tick with the tick spacing of the pool,
 * rounds down according to the asset token denominated price
 * @param tick Tick to align
 * @param tickSpacing Tick spacing of the pool
 */
function alignTick(bool isToken0, int24 tick, int24 tickSpacing) pure returns (int24) {
    if (isToken0) {
        // Round down if isToken0
        if (tick < 0) {
            // If the tick is negative, we round up (negatively) the negative result to round down
            return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
        } else {
            // Else if positive, we simply round down
            return tick / tickSpacing * tickSpacing;
        }
    } else {
        // Round up if isToken1
        if (tick < 0) {
            // If the tick is negative, we round down the negative result to round up
            return tick / tickSpacing * tickSpacing;
        } else {
            // Else if positive, we simply round up
            return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
        }
    }
}

/**
 * @dev Checks if a tick is valid according to the tick spacing, reverts if not
 * @param tick Tick to check
 * @param tickSpacing Tick spacing to check against
 */
function isTickAligned(int24 tick, int24 tickSpacing) pure {
    if (tick % tickSpacing != 0) revert TickNotAligned(tick);
}

/**
 * @dev Checks if a tick range is ordered, reverts if not
 * @param tickLower Lower tick of the range
 * @param tickUpper Upper tick of the range
 */
function isRangeOrdered(int24 tickLower, int24 tickUpper) pure {
    if (tickLower > tickUpper) revert TickRangeMisordered(tickLower, tickUpper);
}

/**
 * @dev Checks if a tick spacing is valid according to Uniswap V4 constraints, reverts if not
 * @param tickSpacing Tick spacing to check
 */
function isTickSpacingValid(
    int24 tickSpacing
) pure {
    require(tickSpacing <= TickMath.MAX_TICK_SPACING, IPoolManager.TickSpacingTooLarge(tickSpacing));
    require(tickSpacing >= TickMath.MIN_TICK_SPACING, IPoolManager.TickSpacingTooSmall(tickSpacing));
}
