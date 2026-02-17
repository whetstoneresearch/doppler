// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {alignTick, alignTickTowardZero} from "src/libraries/TickLibrary.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";

/// @title TickAlignmentTest
/// @notice Tests for tick alignment functions used in OpeningAuctionInitializer
contract TickAlignmentTest is Test {
    int24 constant TICK_SPACING_60 = 60;
    int24 constant TICK_SPACING_200 = 200;
    int24 constant TICK_SPACING_1 = 1;

    // ============ alignTick for isToken0=true ============

    /// @notice For isToken0=true, tick should round toward more negative (down)
    function test_alignTick_isToken0_roundsDown() public pure {
        // -100 with spacing 60 should become -120 (more negative)
        int24 result = alignTick(true, -100, TICK_SPACING_60);
        assertEq(result, -120, "Should round down to -120");
    }

    /// @notice For isToken0=true, already aligned tick stays same
    function test_alignTick_isToken0_alreadyAligned() public pure {
        int24 result = alignTick(true, -120, TICK_SPACING_60);
        assertEq(result, -120, "Already aligned should stay same");
    }

    /// @notice For isToken0=true, positive tick rounds down
    function test_alignTick_isToken0_positiveTick() public pure {
        int24 result = alignTick(true, 100, TICK_SPACING_60);
        assertEq(result, 60, "Positive tick should round down");
    }

    /// @notice For isToken0=true, tick at zero stays zero
    function test_alignTick_isToken0_zeroTick() public pure {
        int24 result = alignTick(true, 0, TICK_SPACING_60);
        assertEq(result, 0, "Zero should stay zero");
    }

    /// @notice For isToken0=true with spacing 1, any tick is valid
    function test_alignTick_isToken0_spacingOne() public pure {
        int24 result = alignTick(true, -12345, TICK_SPACING_1);
        assertEq(result, -12345, "Spacing 1 should not change tick");
    }

    // ============ alignTick for isToken0=false ============

    /// @notice For isToken0=false, tick should round toward more positive (up)
    function test_alignTick_isToken1_roundsUp() public pure {
        // -100 with spacing 60 should become -60 (more positive)
        int24 result = alignTick(false, -100, TICK_SPACING_60);
        assertEq(result, -60, "Should round up to -60");
    }

    /// @notice For isToken0=false, already aligned tick stays same
    function test_alignTick_isToken1_alreadyAligned() public pure {
        int24 result = alignTick(false, -120, TICK_SPACING_60);
        assertEq(result, -120, "Already aligned should stay same");
    }

    /// @notice For isToken0=false, positive tick rounds up
    function test_alignTick_isToken1_positiveTick() public pure {
        int24 result = alignTick(false, 100, TICK_SPACING_60);
        assertEq(result, 120, "Positive tick should round up");
    }

    /// @notice For isToken0=false, tick at zero stays zero
    function test_alignTick_isToken1_zeroTick() public pure {
        int24 result = alignTick(false, 0, TICK_SPACING_60);
        assertEq(result, 0, "Zero should stay zero");
    }

    // ============ alignTickTowardZero ============

    /// @notice Negative tick should round toward zero (up)
    function test_alignTickTowardZero_negativeTick() public pure {
        int24 result = alignTickTowardZero(-100, TICK_SPACING_60);
        assertEq(result, -60, "Should round toward zero");
    }

    /// @notice Positive tick should round toward zero (down)
    function test_alignTickTowardZero_positiveTick() public pure {
        int24 result = alignTickTowardZero(100, TICK_SPACING_60);
        assertEq(result, 60, "Should round toward zero");
    }

    /// @notice Already aligned tick stays same
    function test_alignTickTowardZero_alreadyAligned() public pure {
        int24 result = alignTickTowardZero(-120, TICK_SPACING_60);
        assertEq(result, -120, "Already aligned should stay same");
    }

    // ============ Edge Cases ============

    /// @notice Test alignment at MIN_TICK boundary
    /// Note: MIN_TICK alignment may round toward valid range to avoid underflow
    function test_alignTick_atMinTick() public pure {
        int24 tickSpacing = 60;
        
        // For isToken0=true at MIN_TICK, alignTick rounds down which may go below MIN_TICK
        // The caller is responsible for clamping to valid range
        int24 aligned = alignTick(true, TickMath.MIN_TICK, tickSpacing);
        
        // Verify it's aligned to spacing
        assertEq(aligned % tickSpacing, 0, "Should be aligned to spacing");
        
        // Note: aligned may be < MIN_TICK (-887280 vs -887272) because alignTick
        // doesn't clamp. This test documents that behavior.
        // The actual value is -887280 which is properly aligned to 60
        assertEq(aligned, int24(-887280), "Should align MIN_TICK down to -887280");
    }

    /// @notice Test alignment at MAX_TICK boundary
    function test_alignTick_atMaxTick() public pure {
        int24 maxAligned = (TickMath.MAX_TICK / TICK_SPACING_60) * TICK_SPACING_60;
        int24 result = alignTick(true, TickMath.MAX_TICK, TICK_SPACING_60);
        assertEq(result, maxAligned, "Should align to valid MAX_TICK multiple");
    }

    /// @notice Test alignment with large tick spacing
    function test_alignTick_largeSpacing() public pure {
        // -50 with spacing 200 for isToken0=true should become -200
        int24 result = alignTick(true, -50, TICK_SPACING_200);
        assertEq(result, -200, "Should round to -200");
    }

    /// @notice Fuzz test: aligned tick is always a multiple of spacing
    function testFuzz_alignTick_isMultipleOfSpacing(int24 tick, bool isToken0) public pure {
        // Bound tick to valid range
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        
        int24 result = alignTick(isToken0, tick, TICK_SPACING_60);
        assertEq(result % TICK_SPACING_60, 0, "Result should be multiple of spacing");
    }

    /// @notice Fuzz test: alignment doesn't change direction excessively
    function testFuzz_alignTick_boundedChange(int24 tick, bool isToken0) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK + 60, TickMath.MAX_TICK - 60));
        
        int24 result = alignTick(isToken0, tick, TICK_SPACING_60);
        
        // Change should be less than one tick spacing
        int24 diff = result > tick ? result - tick : tick - result;
        assertLt(diff, TICK_SPACING_60, "Change should be less than spacing");
    }

    /// @notice Test that clearing tick alignment works for Doppler transition
    /// When auction clears at tick -34019 with auction spacing 60, but Doppler uses spacing 200,
    /// the clearing tick needs to be aligned to Doppler spacing
    function test_alignTick_auctionToDopplerTransition() public pure {
        int24 auctionClearingTick = -34019; // Not aligned to any spacing
        int24 dopplerSpacing = 200;
        
        // For isToken0=true (price moving down), align down
        int24 alignedIsToken0 = alignTick(true, auctionClearingTick, dopplerSpacing);
        assertEq(alignedIsToken0 % dopplerSpacing, 0, "Should be aligned to Doppler spacing");
        assertLe(alignedIsToken0, auctionClearingTick, "For isToken0, should not increase tick");
        
        // For isToken0=false (price moving up), align up
        int24 alignedIsToken1 = alignTick(false, auctionClearingTick, dopplerSpacing);
        assertEq(alignedIsToken1 % dopplerSpacing, 0, "Should be aligned to Doppler spacing");
        assertGe(alignedIsToken1, auctionClearingTick, "For isToken1, should not decrease tick");
    }
}
