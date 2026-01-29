// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { alignTick } from "src/libraries/TickLibrary.sol";

/// @title ClearingTickAlignmentAsymmetryTest
/// @notice Demonstrates the asymmetry caused by using _floorToSpacing instead of alignTick
/// @dev Issue: _floorToSpacing always rounds toward negative infinity, but for symmetric
///      "in range" behavior between isToken0=true and isToken0=false, we need:
///        - isToken0=true: round DOWN (toward -infinity) - more positions locked
///        - isToken0=false: round UP (toward +infinity) - more positions locked
///
///      The current _floorToSpacing implementation causes:
///        - isToken0=true auctions to be MORE conservative (lock more positions)
///        - isToken0=false auctions to be LESS conservative (lock fewer positions)
contract ClearingTickAlignmentAsymmetryTest is Test {
    int24 constant TICK_SPACING = 60;

    /// @notice Replicates the _floorToSpacing function from OpeningAuction.sol
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed * spacing;
    }

    /// @notice Replicates the _wouldBeFilled logic from OpeningAuction.sol
    function _wouldBeFilled(bool isToken0, int24 estimatedClearingTick, int24 tickLower, int24 tickSpacing)
        internal
        pure
        returns (bool)
    {
        int24 tickUpper = tickLower + tickSpacing;
        if (isToken0) {
            // For isToken0=true: position is filled if clearing tick is below tickUpper
            return estimatedClearingTick < tickUpper;
        } else {
            // For isToken0=false: position is filled if clearing tick is at or above tickLower
            return estimatedClearingTick >= tickLower;
        }
    }

    /// @notice Demonstrates the asymmetry with negative ticks (common case)
    /// @dev This shows that using _floorToSpacing causes different "conservativeness"
    ///      between isToken0=true and isToken0=false auctions
    function test_asymmetry_negativeTick() public pure {
        // Scenario: raw clearing tick is -65 (between -120 and -60 on spacing=60)
        // The tick needs to be aligned to a multiple of 60
        int24 rawClearingTick = -65;

        // Current behavior: _floorToSpacing always rounds toward -infinity
        int24 flooredTick = _floorToSpacing(rawClearingTick, TICK_SPACING);
        assert(flooredTick == -120); // -65 floors to -120

        // What alignTick would do:
        int24 alignedToken0 = alignTick(true, rawClearingTick, TICK_SPACING);  // rounds down
        int24 alignedToken1 = alignTick(false, rawClearingTick, TICK_SPACING); // rounds up

        assert(alignedToken0 == -120); // rounds down to -120
        assert(alignedToken1 == -60);  // rounds up to -60

        // Now test "in range" behavior for a position at tickLower = -120
        int24 testTickLower = -120;

        // WITH CURRENT _floorToSpacing (both use -120):
        // isToken0=true:  clearingTick=-120 < tickUpper=-60 => IN RANGE (locked)
        // isToken0=false: clearingTick=-120 >= tickLower=-120 => IN RANGE (locked)
        bool filledToken0_current = _wouldBeFilled(true, flooredTick, testTickLower, TICK_SPACING);
        bool filledToken1_current = _wouldBeFilled(false, flooredTick, testTickLower, TICK_SPACING);

        assert(filledToken0_current == true);  // LOCKED
        assert(filledToken1_current == true);  // LOCKED - but only because tick is exactly on boundary

        // Now test at tickLower = -60 (the boundary case that shows asymmetry)
        int24 boundaryTickLower = -60;

        // WITH CURRENT _floorToSpacing (both use -120):
        // isToken0=true:  clearingTick=-120 < tickUpper=0 => IN RANGE (locked)
        // isToken0=false: clearingTick=-120 >= tickLower=-60 => NOT IN RANGE (unlocked!)
        bool filledToken0_boundary = _wouldBeFilled(true, flooredTick, boundaryTickLower, TICK_SPACING);
        bool filledToken1_boundary = _wouldBeFilled(false, flooredTick, boundaryTickLower, TICK_SPACING);

        assert(filledToken0_boundary == true);   // LOCKED - correct conservative behavior
        assert(filledToken1_boundary == false);  // NOT LOCKED - asymmetric!

        // WITH alignTick (token0 uses -120, token1 uses -60):
        // isToken0=true:  clearingTick=-120 < tickUpper=0 => IN RANGE (locked)
        // isToken0=false: clearingTick=-60 >= tickLower=-60 => IN RANGE (locked)
        bool filledToken0_aligned = _wouldBeFilled(true, alignedToken0, boundaryTickLower, TICK_SPACING);
        bool filledToken1_aligned = _wouldBeFilled(false, alignedToken1, boundaryTickLower, TICK_SPACING);

        assert(filledToken0_aligned == true);  // LOCKED
        assert(filledToken1_aligned == true);  // LOCKED - symmetric behavior!
    }

    /// @notice Demonstrates the asymmetry with positive ticks
    function test_asymmetry_positiveTick() public pure {
        // Scenario: raw clearing tick is +65 (between +60 and +120 on spacing=60)
        int24 rawClearingTick = 65;

        // Current behavior: _floorToSpacing rounds toward -infinity (which is "down" for positive)
        int24 flooredTick = _floorToSpacing(rawClearingTick, TICK_SPACING);
        assert(flooredTick == 60); // 65 floors to 60

        // What alignTick would do:
        int24 alignedToken0 = alignTick(true, rawClearingTick, TICK_SPACING);  // rounds down
        int24 alignedToken1 = alignTick(false, rawClearingTick, TICK_SPACING); // rounds up

        assert(alignedToken0 == 60);  // rounds down to 60
        assert(alignedToken1 == 120); // rounds up to 120

        // Test "in range" behavior for position at tickLower = 60
        int24 testTickLower = 60;

        // WITH CURRENT _floorToSpacing (both use 60):
        // isToken0=true:  clearingTick=60 < tickUpper=120 => IN RANGE
        // isToken0=false: clearingTick=60 >= tickLower=60 => IN RANGE
        bool filledToken0_current = _wouldBeFilled(true, flooredTick, testTickLower, TICK_SPACING);
        bool filledToken1_current = _wouldBeFilled(false, flooredTick, testTickLower, TICK_SPACING);

        assert(filledToken0_current == true);
        assert(filledToken1_current == true);

        // Test at tickLower = 120 (boundary case showing asymmetry)
        int24 boundaryTickLower = 120;

        // WITH CURRENT _floorToSpacing (both use 60):
        // isToken0=true:  clearingTick=60 < tickUpper=180 => IN RANGE (locked)
        // isToken0=false: clearingTick=60 >= tickLower=120 => NOT IN RANGE (unlocked!)
        bool filledToken0_boundary = _wouldBeFilled(true, flooredTick, boundaryTickLower, TICK_SPACING);
        bool filledToken1_boundary = _wouldBeFilled(false, flooredTick, boundaryTickLower, TICK_SPACING);

        assert(filledToken0_boundary == true);   // LOCKED
        assert(filledToken1_boundary == false);  // NOT LOCKED - asymmetric!

        // WITH alignTick (token0 uses 60, token1 uses 120):
        // isToken0=true:  clearingTick=60 < tickUpper=180 => IN RANGE (locked)
        // isToken0=false: clearingTick=120 >= tickLower=120 => IN RANGE (locked)
        bool filledToken0_aligned = _wouldBeFilled(true, alignedToken0, boundaryTickLower, TICK_SPACING);
        bool filledToken1_aligned = _wouldBeFilled(false, alignedToken1, boundaryTickLower, TICK_SPACING);

        assert(filledToken0_aligned == true);  // LOCKED
        assert(filledToken1_aligned == true);  // LOCKED - symmetric!
    }

    /// @notice Demonstrates that isToken0=false auctions lock FEWER positions than isToken0=true
    /// @dev This is the core issue: the two auction types have different conservativeness
    function test_asymmetry_lockedPositionCount() public pure {
        // Consider positions at ticks: -180, -120, -60, 0, 60, 120
        int24[6] memory tickLowers = [int24(-180), int24(-120), int24(-60), int24(0), int24(60), int24(120)];

        // Raw clearing tick that falls between boundaries
        int24 rawClearingTick = -65;

        // Current: both use floored tick = -120
        int24 flooredTick = _floorToSpacing(rawClearingTick, TICK_SPACING);

        // With alignTick: token0 uses -120, token1 uses -60
        int24 alignedToken0 = alignTick(true, rawClearingTick, TICK_SPACING);
        int24 alignedToken1 = alignTick(false, rawClearingTick, TICK_SPACING);

        // Count locked positions with current implementation
        uint256 lockedToken0_current = 0;
        uint256 lockedToken1_current = 0;

        for (uint256 i = 0; i < 6; i++) {
            if (_wouldBeFilled(true, flooredTick, tickLowers[i], TICK_SPACING)) {
                lockedToken0_current++;
            }
            if (_wouldBeFilled(false, flooredTick, tickLowers[i], TICK_SPACING)) {
                lockedToken1_current++;
            }
        }

        // Count locked positions with alignTick
        uint256 lockedToken0_aligned = 0;
        uint256 lockedToken1_aligned = 0;

        for (uint256 i = 0; i < 6; i++) {
            if (_wouldBeFilled(true, alignedToken0, tickLowers[i], TICK_SPACING)) {
                lockedToken0_aligned++;
            }
            if (_wouldBeFilled(false, alignedToken1, tickLowers[i], TICK_SPACING)) {
                lockedToken1_aligned++;
            }
        }

        // ASYMMETRY: With _floorToSpacing, isToken0=false locks FEWER positions
        // isToken0=true with clearingTick=-120: locks all positions with tickUpper > -120
        //   => -180 (tickUpper=-120, NOT locked), -120 (tickUpper=-60, locked), -60, 0, 60, 120 = 5 locked
        // isToken0=false with clearingTick=-120: locks all positions with tickLower <= -120
        //   => -180 (locked), -120 (locked) = 2 locked
        assert(lockedToken0_current == 5);
        assert(lockedToken1_current == 2);

        // The asymmetry: isToken0=true locks 5, isToken0=false locks only 2!
        assert(lockedToken0_current > lockedToken1_current); // ASYMMETRIC

        // With alignTick, behavior would be more symmetric
        // isToken0=true with clearingTick=-120: 5 locked (same as before)
        // isToken0=false with clearingTick=-60: locks all positions with tickLower <= -60
        //   => -180 (locked), -120 (locked), -60 (locked) = 3 locked
        assert(lockedToken0_aligned == 5);
        assert(lockedToken1_aligned == 3);

        // Still not perfectly symmetric due to different semantics, but token1 locks MORE
        // positions when using alignTick (3 vs 2), making it more conservative
        assert(lockedToken1_aligned > lockedToken1_current);
    }

    /// @notice The fix: use alignTick instead of _floorToSpacing in _updateClearingTickAndTimeStates
    /// @dev This test documents what the fix should look like
    function test_fix_useAlignTick() public pure {
        int24 rawClearingTick = -65;
        bool isToken0 = false;

        // Current (incorrect for isToken0=false):
        int24 currentResult = _floorToSpacing(rawClearingTick, TICK_SPACING);

        // Fixed:
        int24 fixedResult = alignTick(isToken0, rawClearingTick, TICK_SPACING);

        // For isToken0=false, alignTick rounds UP, giving a more conservative clearing tick
        assert(currentResult == -120);  // rounds down (less conservative for isToken0=false)
        assert(fixedResult == -60);     // rounds up (more conservative for isToken0=false)

        // This means with the fix, more positions would be considered "in range" and locked
        // during the auction, which is the correct conservative behavior
    }
}
