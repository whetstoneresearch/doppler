// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { BitMath } from "@v4-core/libraries/BitMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev Adapted from Jun1on/view-quoter-v4 for use with our v4-core version
library PoolTickBitmap {
    using StateLibrary for IPoolManager;

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256));
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word)
    function nextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tickSpacing,
        int24 tick,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(type(uint8).max) - bitPos)) * tickSpacing;
        }
    }
}
