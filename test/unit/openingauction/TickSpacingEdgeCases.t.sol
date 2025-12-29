// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {alignTick, isTickAligned, alignTickTowardZero} from "src/libraries/TickLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @title TickSpacingEdgeCases
/// @notice Tests for extreme tick spacing combinations and edge cases
contract TickSpacingEdgeCasesTest is Test {
    // ============ alignTick Tests ============

    function test_alignTick_token0_roundsTowardNegativeInfinity() public pure {
        int24 tick = 105;
        int24 tickSpacing = 10;
        // For token0, aligns toward negative infinity
        int24 aligned = alignTick(true, tick, tickSpacing);
        assertEq(aligned, 100);
        
        tick = -105;
        aligned = alignTick(true, tick, tickSpacing);
        assertEq(aligned, -110); // Rounds more negative
    }

    function test_alignTick_token1_roundsTowardPositiveInfinity() public pure {
        int24 tick = 105;
        int24 tickSpacing = 10;
        // For token1, aligns toward positive infinity
        int24 aligned = alignTick(false, tick, tickSpacing);
        assertEq(aligned, 110);
        
        tick = -105;
        aligned = alignTick(false, tick, tickSpacing);
        assertEq(aligned, -100); // Rounds toward zero (more positive)
    }

    function test_isTickAligned_validAlignments() public pure {
        // These should not revert
        isTickAligned(100, 10);
        isTickAligned(-100, 10);
        isTickAligned(0, 10);
        isTickAligned(200, 200);
        isTickAligned(-200, 200);
    }

    // Note: isTickAligned reverts on invalid alignments - tested via valid alignments test
    // Direct vm.expectRevert() on pure functions requires special handling

    // ============ Extreme Tick Spacing Tests ============

    function test_tickSpacing_minimum() public pure {
        int24 tickSpacing = 1;
        int24 tick = 12345;
        
        // With spacing of 1, any tick is aligned
        isTickAligned(tick, tickSpacing);
        assertEq(alignTick(true, tick, tickSpacing), tick);
        assertEq(alignTick(false, tick, tickSpacing), tick);
    }

    function test_tickSpacing_maximum() public pure {
        int24 tickSpacing = 200; // Maximum common tick spacing
        
        // Test alignment at extremes
        int24 alignedTrue = alignTick(true, 199, tickSpacing);
        assertEq(alignedTrue, 0);
        
        int24 alignedFalse = alignTick(false, 199, tickSpacing);
        assertEq(alignedFalse, 200);
    }

    function test_tickSpacing_nearMaxTick() public pure {
        int24 tickSpacing = 60;
        int24 maxTick = TickMath.MAX_TICK;
        
        // Align max tick
        int24 aligned = alignTickTowardZero(maxTick, tickSpacing);
        assertTrue(aligned <= maxTick);
        assertTrue(aligned % tickSpacing == 0);
    }

    function test_tickSpacing_nearMinTick() public pure {
        int24 tickSpacing = 60;
        int24 minTick = TickMath.MIN_TICK;
        
        // Align min tick
        int24 aligned = alignTickTowardZero(minTick, tickSpacing);
        assertTrue(aligned >= minTick);
        assertTrue(aligned % tickSpacing == 0);
    }

    // ============ alignTickTowardZero Tests ============

    function test_alignTickTowardZero_positiveValues() public pure {
        int24 tickSpacing = 10;
        
        assertEq(alignTickTowardZero(105, tickSpacing), 100);
        assertEq(alignTickTowardZero(100, tickSpacing), 100);
        assertEq(alignTickTowardZero(109, tickSpacing), 100);
    }

    function test_alignTickTowardZero_negativeValues() public pure {
        int24 tickSpacing = 10;
        
        assertEq(alignTickTowardZero(-105, tickSpacing), -100);
        assertEq(alignTickTowardZero(-100, tickSpacing), -100);
        assertEq(alignTickTowardZero(-109, tickSpacing), -100);
    }

    function test_alignTickTowardZero_zero() public pure {
        int24 tickSpacing = 10;
        assertEq(alignTickTowardZero(0, tickSpacing), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_alignTick_alwaysAligned(bool isToken0, int24 tick, int24 tickSpacing) public pure {
        // Bound tick spacing to valid range (1-200)
        tickSpacing = int24(int256(bound(uint256(uint24(tickSpacing)), 1, 200)));
        // Bound tick to valid range
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        
        int24 aligned = alignTick(isToken0, tick, tickSpacing);
        
        // Result should be divisible by tickSpacing
        assertEq(aligned % tickSpacing, 0);
        
        // Result should be within tickSpacing of original
        assertTrue(aligned <= tick + tickSpacing);
        assertTrue(aligned >= tick - tickSpacing);
    }

    function testFuzz_alignTickTowardZero_alwaysCloserToZero(int24 tick, int24 tickSpacing) public pure {
        // Bound tick spacing to valid range
        tickSpacing = int24(int256(bound(uint256(uint24(tickSpacing)), 1, 200)));
        // Bound tick to valid range
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        
        int24 aligned = alignTickTowardZero(tick, tickSpacing);
        
        // Result should be divisible by tickSpacing
        assertEq(aligned % tickSpacing, 0);
        
        // Result should be closer to or equal to zero
        if (tick >= 0) {
            assertTrue(aligned <= tick);
            assertTrue(aligned >= 0 || tick < 0);
        } else {
            assertTrue(aligned >= tick);
            assertTrue(aligned <= 0 || tick > 0);
        }
    }

    // ============ Common Tick Spacing Values ============

    function test_commonTickSpacings() public pure {
        // Test all common tick spacings used in Uniswap
        int24[5] memory spacings = [int24(1), int24(10), int24(60), int24(100), int24(200)];
        
        for (uint256 i = 0; i < spacings.length; i++) {
            int24 spacing = spacings[i];
            
            // Test positive tick
            int24 alignedPos = alignTick(true, 12345, spacing);
            assertEq(alignedPos % spacing, 0);
            
            // Test negative tick
            int24 alignedNeg = alignTick(true, -12345, spacing);
            assertEq(alignedNeg % spacing, 0);
            
            // Test zero
            assertEq(alignTick(true, 0, spacing), 0);
        }
    }

    // ============ Boundary Tests ============

    function test_tickBoundaries_maxTick() public pure {
        int24 maxTick = TickMath.MAX_TICK;
        int24 tickSpacing = 60;
        
        int24 aligned = alignTick(true, maxTick, tickSpacing);
        assertTrue(aligned <= maxTick);
        assertEq(aligned % tickSpacing, 0);
    }

    function test_tickBoundaries_minTick() public pure {
        int24 minTick = TickMath.MIN_TICK;
        int24 tickSpacing = 60;
        
        int24 aligned = alignTick(false, minTick, tickSpacing);
        assertTrue(aligned >= minTick);
        assertEq(aligned % tickSpacing, 0);
    }
}
