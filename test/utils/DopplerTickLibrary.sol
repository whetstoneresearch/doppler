// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library DopplerTickLibrary {
    /// @notice Aligns a given tick with the tickSpacing of the pool
    ///         Rounds down according to the asset token denominated price
    /// @dev Copied from Doppler.sol
    /// @param tick The tick to align
    /// @param tickSpacing The tick spacing of the pool
    function alignComputedTickWithTickSpacing(
        bool isToken0,
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
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
}
