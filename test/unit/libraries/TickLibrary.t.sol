// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

import {
    TickNotAligned,
    TickRangeMisordered,
    alignTick,
    alignTickTowardZero,
    isRangeOrdered,
    isTickAligned,
    isTickSpacingValid
} from "src/libraries/TickLibrary.sol";

contract TickLibraryTest is Test {
    // ============ alignTick Tests ============

    function test_alignTick_BasicCases() public pure {
        // isToken0=true rounds DOWN (away from zero for negative, toward zero for positive)
        assertEq(alignTick(true, -3, 2), int24(-4));
        assertEq(alignTick(true, 3, 2), int24(2));

        // isToken0=false rounds UP (toward zero for negative, away from zero for positive)
        assertEq(alignTick(false, -3, 2), int24(-2));
        assertEq(alignTick(false, 3, 2), int24(4));
    }

    function test_alignTick_MaxTick() public pure {
        // MAX_TICK = 887272, spacing = 60
        // isToken0=true: round down -> 887220
        assertEq(alignTick(true, TickMath.MAX_TICK, 60), int24(887220));

        // isToken0=false: round up -> 887280 (but capped at MAX_TICK in practice)
        // Note: This goes ABOVE MAX_TICK which may be invalid for pool operations
        assertEq(alignTick(false, TickMath.MAX_TICK, 60), int24(887280));
    }

    function test_alignTick_MinTick() public pure {
        // MIN_TICK = -887272, spacing = 60
        // isToken0=true: round down -> -887280 (below MIN_TICK, may be invalid)
        assertEq(alignTick(true, TickMath.MIN_TICK, 60), int24(-887280));

        // isToken0=false: round up -> -887220
        assertEq(alignTick(false, TickMath.MIN_TICK, 60), int24(-887220));
    }

    function test_alignTick_ZeroTick() public pure {
        // Zero is already aligned to any spacing
        assertEq(alignTick(true, 0, 60), int24(0));
        assertEq(alignTick(false, 0, 60), int24(0));
    }

    function test_alignTick_AlreadyAligned() public pure {
        // Already aligned ticks should stay the same
        assertEq(alignTick(true, 120, 60), int24(120));
        assertEq(alignTick(false, 120, 60), int24(120));
        assertEq(alignTick(true, -120, 60), int24(-120));
        assertEq(alignTick(false, -120, 60), int24(-120));
    }

    function test_alignTick_VariousSpacings() public pure {
        // Spacing = 1 (no alignment needed)
        assertEq(alignTick(true, 123, 1), int24(123));
        assertEq(alignTick(false, -123, 1), int24(-123));

        // Spacing = 200
        assertEq(alignTick(true, 150, 200), int24(0));      // round down
        assertEq(alignTick(false, 150, 200), int24(200));   // round up
        assertEq(alignTick(true, -150, 200), int24(-200));  // round down (more negative)
        assertEq(alignTick(false, -150, 200), int24(0));    // round up (toward zero)
    }

    // ============ alignTickTowardZero Tests ============

    function test_alignTickTowardZero_BasicCases() public pure {
        // Positive ticks: round toward zero (down)
        assertEq(alignTickTowardZero(3, 2), int24(2));
        assertEq(alignTickTowardZero(5, 2), int24(4));

        // Negative ticks: round toward zero (up, i.e., less negative)
        assertEq(alignTickTowardZero(-3, 2), int24(-2));
        assertEq(alignTickTowardZero(-5, 2), int24(-4));
    }

    function test_alignTickTowardZero_MaxTick() public pure {
        // MAX_TICK = 887272, spacing = 60
        // 887272 % 60 = 52
        // 887272 - 52 = 887220
        assertEq(alignTickTowardZero(TickMath.MAX_TICK, 60), int24(887220));

        // Verify it's properly aligned
        assertEq(int24(887220) % 60, int24(0));
    }

    function test_alignTickTowardZero_MinTick() public pure {
        // MIN_TICK = -887272, spacing = 60
        // -887272 % 60 = -52 (Solidity preserves sign)
        // -887272 - (-52) = -887220
        assertEq(alignTickTowardZero(TickMath.MIN_TICK, 60), int24(-887220));

        // Verify it's properly aligned
        assertEq(int24(-887220) % 60, int24(0));
    }

    function test_alignTickTowardZero_ZeroTick() public pure {
        assertEq(alignTickTowardZero(0, 60), int24(0));
        assertEq(alignTickTowardZero(0, 1), int24(0));
        assertEq(alignTickTowardZero(0, 200), int24(0));
    }

    function test_alignTickTowardZero_AlreadyAligned() public pure {
        assertEq(alignTickTowardZero(120, 60), int24(120));
        assertEq(alignTickTowardZero(-120, 60), int24(-120));
        assertEq(alignTickTowardZero(600, 200), int24(600));
        assertEq(alignTickTowardZero(-600, 200), int24(-600));
    }

    function test_alignTickTowardZero_VariousSpacings() public pure {
        // Spacing = 1 (no change)
        assertEq(alignTickTowardZero(123, 1), int24(123));
        assertEq(alignTickTowardZero(-123, 1), int24(-123));

        // Spacing = 200
        assertEq(alignTickTowardZero(150, 200), int24(0));    // 150 - 150 = 0
        assertEq(alignTickTowardZero(-150, 200), int24(0));   // -150 - (-150) = 0
        assertEq(alignTickTowardZero(250, 200), int24(200));  // 250 - 50 = 200
        assertEq(alignTickTowardZero(-250, 200), int24(-200)); // -250 - (-50) = -200
    }

    function test_alignTickTowardZero_ResultIsAlwaysAligned() public pure {
        int24[7] memory ticks = [int24(887272), int24(-887272), int24(12345), int24(-12345), int24(1), int24(-1), int24(0)];
        int24[4] memory spacings = [int24(1), int24(60), int24(100), int24(200)];

        for (uint256 i = 0; i < ticks.length; i++) {
            for (uint256 j = 0; j < spacings.length; j++) {
                int24 aligned = alignTickTowardZero(ticks[i], spacings[j]);
                assertEq(aligned % spacings[j], int24(0), "Result should be aligned");
            }
        }
    }

    function test_alignTickTowardZero_ResultIsBetweenInputAndZero() public pure {
        int24[6] memory ticks = [int24(887272), int24(-887272), int24(12345), int24(-12345), int24(59), int24(-59)];
        int24[3] memory spacings = [int24(60), int24(100), int24(200)];

        for (uint256 i = 0; i < ticks.length; i++) {
            for (uint256 j = 0; j < spacings.length; j++) {
                int24 tick = ticks[i];
                int24 aligned = alignTickTowardZero(tick, spacings[j]);

                if (tick >= 0) {
                    assertTrue(aligned <= tick, "Positive: aligned should be <= tick");
                    assertTrue(aligned >= 0, "Positive: aligned should be >= 0");
                } else {
                    assertTrue(aligned >= tick, "Negative: aligned should be >= tick");
                    assertTrue(aligned <= 0, "Negative: aligned should be <= 0");
                }
            }
        }
    }

    // ============ Comparison: alignTick vs alignTickTowardZero ============

    function test_compare_alignFunctions_MaxTickIsToken0() public pure {
        // For MAX_TICK with isToken0=true, both should give same result
        int24 fromAlignTick = alignTick(true, TickMath.MAX_TICK, 60);
        int24 fromAlignTowardZero = alignTickTowardZero(TickMath.MAX_TICK, 60);
        assertEq(fromAlignTick, fromAlignTowardZero, "Should match for MAX_TICK isToken0=true");
    }

    function test_compare_alignFunctions_MinTickIsToken1() public pure {
        // For MIN_TICK with isToken0=false, both should give same result
        int24 fromAlignTick = alignTick(false, TickMath.MIN_TICK, 60);
        int24 fromAlignTowardZero = alignTickTowardZero(TickMath.MIN_TICK, 60);
        assertEq(fromAlignTick, fromAlignTowardZero, "Should match for MIN_TICK isToken0=false");
    }

    function test_compare_alignFunctions_Differ() public pure {
        // These cases show where the functions differ

        // Negative tick with isToken0=true: alignTick rounds away from zero
        assertEq(alignTick(true, -100, 60), int24(-120));        // rounds down (away from zero)
        assertEq(alignTickTowardZero(-100, 60), int24(-60));     // rounds toward zero

        // Positive tick with isToken0=false: alignTick rounds away from zero
        assertEq(alignTick(false, 100, 60), int24(120));         // rounds up (away from zero)
        assertEq(alignTickTowardZero(100, 60), int24(60));       // rounds toward zero
    }

    function test_isTickAligned(int24 tick, int24 tickSpacing) public pure {
        vm.assume(tickSpacing > 0);
        vm.assume(tick % tickSpacing == 0);
        isTickAligned(tick, tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickAligned_RevertsIfTickNotAligned(int24 tick, int24 tickSpacing) public {
        vm.assume(tickSpacing > 0);
        vm.assume(tick % tickSpacing != 0);
        vm.expectRevert(abi.encodeWithSelector(TickNotAligned.selector, tick));
        isTickAligned(tick, tickSpacing);
    }

    function test_isRangeOrdered(int24 tickLower, int24 tickUpper) public pure {
        vm.assume(tickLower < tickUpper);
        isRangeOrdered(tickLower, tickUpper);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isRangeOrdered_RevertsIfTickRangeMisordered(int24 tickLower, int24 tickUpper) public {
        vm.assume(tickLower > tickUpper);
        vm.expectRevert(abi.encodeWithSelector(TickRangeMisordered.selector, tickLower, tickUpper));
        isRangeOrdered(tickLower, tickUpper);
    }

    function test_isTickSpacingValid(int24 tickSpacing) public pure {
        vm.assume(tickSpacing >= TickMath.MIN_TICK_SPACING);
        vm.assume(tickSpacing <= TickMath.MAX_TICK_SPACING);
        isTickSpacingValid(tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickSpacingValid_RevertsIfTooSmall(int24 tickSpacing) public {
        vm.assume(tickSpacing < 0);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, tickSpacing));
        isTickSpacingValid(tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickSpacingValid_RevertsIfTooLarge(int24 tickSpacing) public {
        vm.assume(tickSpacing > TickMath.MAX_TICK_SPACING);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector, tickSpacing));
        isTickSpacingValid(tickSpacing);
    }
}
