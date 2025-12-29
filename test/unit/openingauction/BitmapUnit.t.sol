// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BitMath } from "@v3-core/libraries/BitMath.sol";

/// @title BitmapHarness
/// @notice Exposes OpeningAuction's internal bitmap functions for unit testing
/// @dev This is an exact copy of the bitmap logic from OpeningAuction.sol for isolated testing
contract BitmapHarness {
    /// @notice Bitmap of active ticks
    mapping(int16 => uint256) public tickBitmap;

    /// @notice Track liquidity for insert/remove logic
    mapping(int24 => uint128) public liquidityAtTick;

    /// @notice Minimum active tick
    int24 public minActiveTick;

    /// @notice Maximum active tick
    int24 public maxActiveTick;

    /// @notice Whether any active ticks exist
    bool public hasActiveTicks;

    /// @notice Count of active ticks
    uint256 public activeTickCount;

    // ============ Exposed Bitmap Functions ============

    /// @notice Computes the position in the bitmap where the bit for a tick lives
    /// @dev Exact copy from OpeningAuction - uses V3-style Solidity implementation
    function position(int24 tick) public pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick) % 256);
    }

    /// @notice Flips the bit for a given tick in the bitmap
    function flipTick(int24 tick) public {
        (int16 wordPos, uint8 bitPos) = position(tick);
        uint256 mask = 1 << bitPos;
        tickBitmap[wordPos] ^= mask;
    }

    /// @notice Check if a tick is set in the bitmap
    function isTickActive(int24 tick) public view returns (bool) {
        (int16 wordPos, uint8 bitPos) = position(tick);
        return (tickBitmap[wordPos] & (1 << bitPos)) != 0;
    }

    /// @notice Returns the next initialized tick in the bitmap
    /// @dev Exact copy from OpeningAuction - uses V3-style mask calculation
    function nextInitializedTickWithinOneWord(int24 tick, bool lte)
        public
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(tick);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
                uint256 masked = tickBitmap[wordPos] & mask;

                initialized = masked != 0;
                next = initialized
                    ? tick - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))
                    : tick - int24(uint24(bitPos));
            } else {
                // start from the word of the next tick
                (int16 wordPos, uint8 bitPos) = position(tick + 1);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = tickBitmap[wordPos] & mask;

                initialized = masked != 0;
                next = initialized
                    ? tick + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))
                    : tick + 1 + int24(uint24(type(uint8).max - bitPos));
            }
        }
    }

    /// @notice Find the next initialized tick, searching across multiple words if needed
    function nextInitializedTick(int24 tick, bool lte, int24 boundTick)
        public
        view
        returns (int24 next, bool found)
    {
        next = tick;
        while (true) {
            (int24 nextTick, bool initialized) = nextInitializedTickWithinOneWord(next, lte);

            if (initialized) {
                return (nextTick, true);
            }

            // Check if we've passed the bound
            if (lte) {
                if (nextTick <= boundTick) return (boundTick, false);
                next = nextTick - 1; // Move to previous word
            } else {
                if (nextTick >= boundTick) return (boundTick, false);
                next = nextTick; // Already moved to next word boundary
            }
        }
    }

    /// @notice Insert a tick into the bitmap
    function insertTick(int24 tick) public {
        // O(1) existence check - if tick has liquidity, it's already in the bitmap
        if (liquidityAtTick[tick] > 0) return;

        // Set some liquidity to mark as inserted
        liquidityAtTick[tick] = 1;

        // Flip the bit to set it
        flipTick(tick);
        activeTickCount++;

        // Update min/max bounds
        if (!hasActiveTicks) {
            minActiveTick = tick;
            maxActiveTick = tick;
            hasActiveTicks = true;
        } else {
            if (tick < minActiveTick) minActiveTick = tick;
            if (tick > maxActiveTick) maxActiveTick = tick;
        }
    }

    /// @notice Remove a tick from the bitmap
    function removeTick(int24 tick) public {
        if (!isTickActive(tick)) return;

        // Clear liquidity
        liquidityAtTick[tick] = 0;

        // Flip the bit to unset it
        flipTick(tick);
        activeTickCount--;

        // Update min/max bounds if needed
        if (activeTickCount == 0) {
            hasActiveTicks = false;
        } else if (tick == minActiveTick) {
            // Find new minimum by walking right
            (int24 newMin, bool found) = nextInitializedTick(tick, false, maxActiveTick + 1);
            if (found) minActiveTick = newMin;
        } else if (tick == maxActiveTick) {
            // Find new maximum by walking left
            (int24 newMax, bool found) = nextInitializedTick(tick, true, minActiveTick - 1);
            if (found) maxActiveTick = newMax;
        }
    }

    // ============ Test Helpers ============

    /// @notice Direct access to set a word in the bitmap (for testing)
    function setWord(int16 wordPos, uint256 value) public {
        tickBitmap[wordPos] = value;
    }

    /// @notice Get a word from the bitmap
    function getWord(int16 wordPos) public view returns (uint256) {
        return tickBitmap[wordPos];
    }
}

/// @title BitmapUnitTest
/// @notice Comprehensive unit tests for OpeningAuction bitmap implementation
/// @dev Tests the bitmap functions in isolation
contract BitmapUnitTest is Test {
    BitmapHarness harness;

    function setUp() public {
        harness = new BitmapHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: _position() Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_position_Zero() public view {
        (int16 wordPos, uint8 bitPos) = harness.position(0);
        assertEq(wordPos, 0, "tick 0 should be in word 0");
        assertEq(bitPos, 0, "tick 0 should be at bit 0");
    }

    function test_position_PositiveSmall() public view {
        // Tick 1 should be word 0, bit 1
        (int16 wordPos, uint8 bitPos) = harness.position(1);
        assertEq(wordPos, 0);
        assertEq(bitPos, 1);

        // Tick 127 should be word 0, bit 127
        (wordPos, bitPos) = harness.position(127);
        assertEq(wordPos, 0);
        assertEq(bitPos, 127);

        // Tick 255 should be word 0, bit 255
        (wordPos, bitPos) = harness.position(255);
        assertEq(wordPos, 0);
        assertEq(bitPos, 255);
    }

    function test_position_PositiveWordBoundary() public view {
        // Tick 256 should be word 1, bit 0 (first tick of next word)
        (int16 wordPos, uint8 bitPos) = harness.position(256);
        assertEq(wordPos, 1, "tick 256 should be in word 1");
        assertEq(bitPos, 0, "tick 256 should be at bit 0");

        // Tick 257 should be word 1, bit 1
        (wordPos, bitPos) = harness.position(257);
        assertEq(wordPos, 1);
        assertEq(bitPos, 1);

        // Tick 511 should be word 1, bit 255
        (wordPos, bitPos) = harness.position(511);
        assertEq(wordPos, 1);
        assertEq(bitPos, 255);

        // Tick 512 should be word 2, bit 0
        (wordPos, bitPos) = harness.position(512);
        assertEq(wordPos, 2);
        assertEq(bitPos, 0);
    }

    function test_position_NegativeSmall() public view {
        // Tick -1 should be word -1, bit 255
        (int16 wordPos, uint8 bitPos) = harness.position(-1);
        assertEq(wordPos, -1, "tick -1 should be in word -1");
        assertEq(bitPos, 255, "tick -1 should be at bit 255");

        // Tick -2 should be word -1, bit 254
        (wordPos, bitPos) = harness.position(-2);
        assertEq(wordPos, -1);
        assertEq(bitPos, 254);

        // Tick -128 should be word -1, bit 128
        (wordPos, bitPos) = harness.position(-128);
        assertEq(wordPos, -1);
        assertEq(bitPos, 128);

        // Tick -255 should be word -1, bit 1
        (wordPos, bitPos) = harness.position(-255);
        assertEq(wordPos, -1);
        assertEq(bitPos, 1);

        // Tick -256 should be word -1, bit 0
        (wordPos, bitPos) = harness.position(-256);
        assertEq(wordPos, -1);
        assertEq(bitPos, 0);
    }

    function test_position_NegativeWordBoundary() public view {
        // Tick -257 should be word -2, bit 255
        (int16 wordPos, uint8 bitPos) = harness.position(-257);
        assertEq(wordPos, -2, "tick -257 should be in word -2");
        assertEq(bitPos, 255, "tick -257 should be at bit 255");

        // Tick -512 should be word -2, bit 0
        (wordPos, bitPos) = harness.position(-512);
        assertEq(wordPos, -2);
        assertEq(bitPos, 0);

        // Tick -513 should be word -3, bit 255
        (wordPos, bitPos) = harness.position(-513);
        assertEq(wordPos, -3);
        assertEq(bitPos, 255);
    }

    function test_position_LargePositive() public view {
        // Tick 10000: 10000 / 256 = 39, 10000 % 256 = 16
        (int16 wordPos, uint8 bitPos) = harness.position(10000);
        assertEq(wordPos, 39);
        assertEq(bitPos, 16);

        // Tick 887272 (near MAX_TICK): 887272 / 256 = 3465, 887272 % 256 = 232
        (wordPos, bitPos) = harness.position(887272);
        assertEq(wordPos, 3465);
        assertEq(bitPos, 232);
    }

    function test_position_LargeNegative() public view {
        // Tick -10000: floor(-10000 / 256) = -40, -10000 & 0xff = 240
        (int16 wordPos, uint8 bitPos) = harness.position(-10000);
        assertEq(wordPos, -40);
        assertEq(bitPos, 240);

        // Tick -887272 (near MIN_TICK)
        (wordPos, bitPos) = harness.position(-887272);
        assertEq(wordPos, -3466);
        assertEq(bitPos, 24);
    }

    function testFuzz_position_Roundtrip(int24 tick) public view {
        // Verify that position gives consistent results
        (int16 wordPos, uint8 bitPos) = harness.position(tick);
        
        // Reconstruct tick from wordPos and bitPos
        int24 reconstructed = int24(wordPos) * 256 + int24(uint24(bitPos));
        assertEq(reconstructed, tick, "position should roundtrip correctly");
    }

    function testFuzz_position_BitPosRange(int24 tick) public view {
        (, uint8 bitPos) = harness.position(tick);
        assertTrue(bitPos < 256, "bitPos should always be < 256");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: _flipTick() and _isTickActive() Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_flipTick_SetAndUnset() public {
        int24 tick = 100;
        
        // Initially not active
        assertFalse(harness.isTickActive(tick), "tick should start inactive");

        // Flip once - should be active
        harness.flipTick(tick);
        assertTrue(harness.isTickActive(tick), "tick should be active after first flip");

        // Flip again - should be inactive
        harness.flipTick(tick);
        assertFalse(harness.isTickActive(tick), "tick should be inactive after second flip");
    }

    function test_flipTick_MultipleTicksSameWord() public {
        int24[] memory ticks = new int24[](5);
        ticks[0] = 0;
        ticks[1] = 50;
        ticks[2] = 100;
        ticks[3] = 150;
        ticks[4] = 255;

        // Flip all ticks on
        for (uint256 i = 0; i < ticks.length; i++) {
            harness.flipTick(ticks[i]);
        }

        // Verify all are active
        for (uint256 i = 0; i < ticks.length; i++) {
            assertTrue(harness.isTickActive(ticks[i]), "tick should be active");
        }

        // Verify word has correct bits set
        uint256 expectedWord = (1 << 0) | (1 << 50) | (1 << 100) | (1 << 150) | (1 << 255);
        assertEq(harness.getWord(0), expectedWord, "word should have correct bits");
    }

    function test_flipTick_DifferentWords() public {
        // Ticks in different words
        int24[] memory ticks = new int24[](4);
        ticks[0] = 0;      // word 0
        ticks[1] = 256;    // word 1
        ticks[2] = -1;     // word -1
        ticks[3] = -257;   // word -2

        for (uint256 i = 0; i < ticks.length; i++) {
            harness.flipTick(ticks[i]);
        }

        // Verify all are active
        for (uint256 i = 0; i < ticks.length; i++) {
            assertTrue(harness.isTickActive(ticks[i]), "tick should be active");
        }

        // Verify each word
        assertEq(harness.getWord(0), 1, "word 0 should have bit 0 set");
        assertEq(harness.getWord(1), 1, "word 1 should have bit 0 set");
        assertEq(harness.getWord(-1), 1 << 255, "word -1 should have bit 255 set");
        assertEq(harness.getWord(-2), 1 << 255, "word -2 should have bit 255 set");
    }

    function test_flipTick_NegativeTicks() public {
        int24[] memory ticks = new int24[](5);
        ticks[0] = -1;
        ticks[1] = -100;
        ticks[2] = -256;
        ticks[3] = -257;
        ticks[4] = -1000;

        for (uint256 i = 0; i < ticks.length; i++) {
            harness.flipTick(ticks[i]);
            assertTrue(harness.isTickActive(ticks[i]), "negative tick should be active after flip");
        }
    }

    function testFuzz_flipTick_Idempotent(int24 tick) public {
        // Double flip should return to original state
        bool stateBefore = harness.isTickActive(tick);
        harness.flipTick(tick);
        harness.flipTick(tick);
        bool stateAfter = harness.isTickActive(tick);
        assertEq(stateBefore, stateAfter, "double flip should be idempotent");
    }

    function testFuzz_flipTick_Independent(int24 tick1, int24 tick2) public {
        vm.assume(tick1 != tick2);
        
        harness.flipTick(tick1);
        assertTrue(harness.isTickActive(tick1));
        assertFalse(harness.isTickActive(tick2));

        harness.flipTick(tick2);
        assertTrue(harness.isTickActive(tick1));
        assertTrue(harness.isTickActive(tick2));

        harness.flipTick(tick1);
        assertFalse(harness.isTickActive(tick1));
        assertTrue(harness.isTickActive(tick2));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: _nextInitializedTickWithinOneWord() Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTickWithinOneWord_LTE_SingleTick() public {
        harness.flipTick(100);

        // Search from 100 going left - should find 100
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(100, true);
        assertTrue(found);
        assertEq(next, 100);

        // Search from 150 going left - should find 100
        (next, found) = harness.nextInitializedTickWithinOneWord(150, true);
        assertTrue(found);
        assertEq(next, 100);

        // Search from 99 going left - should NOT find (100 is to the right)
        (next, found) = harness.nextInitializedTickWithinOneWord(99, true);
        assertFalse(found);
        // next should be at word boundary (tick 0)
        assertEq(next, 0);
    }

    function test_nextInitializedTickWithinOneWord_GTE_SingleTick() public {
        harness.flipTick(100);

        // Search from 99 going right - should find 100
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(99, false);
        assertTrue(found);
        assertEq(next, 100);

        // Search from 50 going right - should find 100
        (next, found) = harness.nextInitializedTickWithinOneWord(50, false);
        assertTrue(found);
        assertEq(next, 100);

        // Search from 100 going right - should NOT find (we start from tick+1)
        (next, found) = harness.nextInitializedTickWithinOneWord(100, false);
        assertFalse(found);
        // next should be at last tick in word (255), then _nextInitializedTick continues from there
        assertEq(next, 255);
    }

    function test_nextInitializedTickWithinOneWord_LTE_MultipleTicks() public {
        harness.flipTick(50);
        harness.flipTick(100);
        harness.flipTick(200);

        // From 255, should find 200 (closest to left)
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(255, true);
        assertTrue(found);
        assertEq(next, 200);

        // From 150, should find 100
        (next, found) = harness.nextInitializedTickWithinOneWord(150, true);
        assertTrue(found);
        assertEq(next, 100);

        // From 75, should find 50
        (next, found) = harness.nextInitializedTickWithinOneWord(75, true);
        assertTrue(found);
        assertEq(next, 50);
    }

    function test_nextInitializedTickWithinOneWord_GTE_MultipleTicks() public {
        harness.flipTick(50);
        harness.flipTick(100);
        harness.flipTick(200);

        // From 0, should find 50 (closest to right)
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(0, false);
        assertTrue(found);
        assertEq(next, 50);

        // From 75, should find 100
        (next, found) = harness.nextInitializedTickWithinOneWord(75, false);
        assertTrue(found);
        assertEq(next, 100);

        // From 150, should find 200
        (next, found) = harness.nextInitializedTickWithinOneWord(150, false);
        assertTrue(found);
        assertEq(next, 200);
    }

    function test_nextInitializedTickWithinOneWord_EmptyWord() public view {
        // No ticks set - should not find anything
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(128, true);
        assertFalse(found);
        assertEq(next, 0); // Should be at start of current word (tick - bitPos)

        (next, found) = harness.nextInitializedTickWithinOneWord(128, false);
        assertFalse(found);
        // Returns last tick in current word: tick + 1 + (255 - bitPos) = 129 + (255 - 129) = 255
        assertEq(next, 255);
    }

    function test_nextInitializedTickWithinOneWord_NegativeTicks_LTE() public {
        // Negative ticks are in word -1
        harness.flipTick(-50);
        harness.flipTick(-100);
        harness.flipTick(-200);

        // From -1 going left, should find -50
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(-1, true);
        assertTrue(found);
        assertEq(next, -50);

        // From -75 going left, should find -100
        (next, found) = harness.nextInitializedTickWithinOneWord(-75, true);
        assertTrue(found);
        assertEq(next, -100);
    }

    function test_nextInitializedTickWithinOneWord_NegativeTicks_GTE() public {
        harness.flipTick(-50);
        harness.flipTick(-100);
        harness.flipTick(-200);

        // From -256 going right, should find -200
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(-256, false);
        assertTrue(found);
        assertEq(next, -200);

        // From -150 going right, should find -100
        (next, found) = harness.nextInitializedTickWithinOneWord(-150, false);
        assertTrue(found);
        assertEq(next, -100);
    }

    function test_nextInitializedTickWithinOneWord_WordBoundary() public {
        // Tick at bit 0 of word 0
        harness.flipTick(0);
        
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(100, true);
        assertTrue(found);
        assertEq(next, 0);

        // Tick at bit 255 of word 0
        harness.flipTick(255);
        
        (next, found) = harness.nextInitializedTickWithinOneWord(200, false);
        assertTrue(found);
        assertEq(next, 255);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: _nextInitializedTick() Cross-Word Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTick_CrossWord_GTE() public {
        // Set tick in word 2 (tick 512)
        harness.flipTick(512);

        // Search from tick 0 going right with bound at 1000
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 1000);
        assertTrue(found);
        assertEq(next, 512);
    }

    function test_nextInitializedTick_CrossWord_LTE() public {
        // Set tick in word -2 (tick -300)
        harness.flipTick(-300);

        // Search from tick 0 going left with bound at -500
        (int24 next, bool found) = harness.nextInitializedTick(0, true, -500);
        assertTrue(found);
        assertEq(next, -300);
    }

    function test_nextInitializedTick_MultipleWords_FindClosest() public {
        harness.flipTick(100);    // word 0
        harness.flipTick(300);    // word 1
        harness.flipTick(600);    // word 2

        // From 0, should find 100 first
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 1000);
        assertTrue(found);
        assertEq(next, 100);

        // From 200, should find 300
        (next, found) = harness.nextInitializedTick(200, false, 1000);
        assertTrue(found);
        assertEq(next, 300);
    }

    function test_nextInitializedTick_HitsBound_GTE() public {
        harness.flipTick(1000);

        // Search with bound before the tick
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 500);
        assertFalse(found);
        assertEq(next, 500); // Returns bound
    }

    function test_nextInitializedTick_HitsBound_LTE() public {
        harness.flipTick(-1000);

        // Search with bound after the tick
        (int24 next, bool found) = harness.nextInitializedTick(0, true, -500);
        assertFalse(found);
        assertEq(next, -500); // Returns bound
    }

    function test_nextInitializedTick_NoTicksInRange() public {
        // No ticks set at all
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 10000);
        assertFalse(found);
        assertEq(next, 10000);

        (next, found) = harness.nextInitializedTick(0, true, -10000);
        assertFalse(found);
        assertEq(next, -10000);
    }

    function test_nextInitializedTick_LargeGap() public {
        // Set ticks with large gap (many empty words between)
        harness.flipTick(0);
        harness.flipTick(10000);  // ~39 words apart

        // Should still find it
        (int24 next, bool found) = harness.nextInitializedTick(100, false, 20000);
        assertTrue(found);
        assertEq(next, 10000);
    }

    function test_nextInitializedTick_ExactMatch() public {
        harness.flipTick(500);

        // Search starting exactly at 500, going right - should NOT find 500 (starts at tick+1)
        (int24 next, bool found) = harness.nextInitializedTick(500, false, 1000);
        assertFalse(found);
        assertEq(next, 1000);

        // Search starting at 500, going left - SHOULD find 500
        (next, found) = harness.nextInitializedTick(500, true, 0);
        assertTrue(found);
        assertEq(next, 500);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: _insertTick() and _removeTick() Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_insertTick_Basic() public {
        assertFalse(harness.hasActiveTicks());
        assertEq(harness.activeTickCount(), 0);

        harness.insertTick(100);

        assertTrue(harness.hasActiveTicks());
        assertEq(harness.activeTickCount(), 1);
        assertTrue(harness.isTickActive(100));
        assertEq(harness.minActiveTick(), 100);
        assertEq(harness.maxActiveTick(), 100);
    }

    function test_insertTick_UpdatesMinMax() public {
        harness.insertTick(100);
        assertEq(harness.minActiveTick(), 100);
        assertEq(harness.maxActiveTick(), 100);

        harness.insertTick(50);
        assertEq(harness.minActiveTick(), 50);
        assertEq(harness.maxActiveTick(), 100);

        harness.insertTick(200);
        assertEq(harness.minActiveTick(), 50);
        assertEq(harness.maxActiveTick(), 200);

        harness.insertTick(75);  // Between min and max - no change
        assertEq(harness.minActiveTick(), 50);
        assertEq(harness.maxActiveTick(), 200);
    }

    function test_insertTick_Duplicate() public {
        harness.insertTick(100);
        assertEq(harness.activeTickCount(), 1);

        // Insert same tick again - should be no-op
        harness.insertTick(100);
        assertEq(harness.activeTickCount(), 1);
        assertTrue(harness.isTickActive(100));
    }

    function test_insertTick_NegativeTicks() public {
        harness.insertTick(-100);
        assertEq(harness.minActiveTick(), -100);
        assertEq(harness.maxActiveTick(), -100);

        harness.insertTick(-200);
        assertEq(harness.minActiveTick(), -200);
        assertEq(harness.maxActiveTick(), -100);

        harness.insertTick(50);
        assertEq(harness.minActiveTick(), -200);
        assertEq(harness.maxActiveTick(), 50);
    }

    function test_removeTick_Basic() public {
        harness.insertTick(100);
        assertTrue(harness.isTickActive(100));

        harness.removeTick(100);
        assertFalse(harness.isTickActive(100));
        assertFalse(harness.hasActiveTicks());
        assertEq(harness.activeTickCount(), 0);
    }

    function test_removeTick_UpdatesMin() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        assertEq(harness.minActiveTick(), 50);

        // Remove min - should update to next tick
        harness.removeTick(50);
        assertEq(harness.minActiveTick(), 100);
        assertEq(harness.activeTickCount(), 2);
    }

    function test_removeTick_UpdatesMax() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        assertEq(harness.maxActiveTick(), 150);

        // Remove max - should update to previous tick
        harness.removeTick(150);
        assertEq(harness.maxActiveTick(), 100);
        assertEq(harness.activeTickCount(), 2);
    }

    function test_removeTick_MiddleTick() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        // Remove middle tick - min/max unchanged
        harness.removeTick(100);
        assertEq(harness.minActiveTick(), 50);
        assertEq(harness.maxActiveTick(), 150);
        assertEq(harness.activeTickCount(), 2);
    }

    function test_removeTick_NonExistent() public {
        harness.insertTick(100);
        assertEq(harness.activeTickCount(), 1);

        // Remove non-existent tick - should be no-op
        harness.removeTick(200);
        assertEq(harness.activeTickCount(), 1);
        assertTrue(harness.isTickActive(100));
    }

    function test_removeTick_AllTicks() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        harness.removeTick(50);
        harness.removeTick(100);
        harness.removeTick(150);

        assertFalse(harness.hasActiveTicks());
        assertEq(harness.activeTickCount(), 0);
    }

    function test_removeTick_CrossWord() public {
        // Insert ticks across multiple words
        harness.insertTick(0);      // word 0
        harness.insertTick(300);    // word 1
        harness.insertTick(600);    // word 2

        assertEq(harness.minActiveTick(), 0);
        assertEq(harness.maxActiveTick(), 600);

        // Remove min - should find 300 as new min
        harness.removeTick(0);
        assertEq(harness.minActiveTick(), 300);

        // Remove max - should find 300 as new max
        harness.removeTick(600);
        assertEq(harness.maxActiveTick(), 300);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: Edge Cases and Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_edgeCase_MaxTick() public {
        int24 maxTick = 887272;  // Near TickMath.MAX_TICK
        
        harness.insertTick(maxTick);
        assertTrue(harness.isTickActive(maxTick));
        assertEq(harness.maxActiveTick(), maxTick);
    }

    function test_edgeCase_MinTick() public {
        int24 minTick = -887272;  // Near TickMath.MIN_TICK
        
        harness.insertTick(minTick);
        assertTrue(harness.isTickActive(minTick));
        assertEq(harness.minActiveTick(), minTick);
    }

    function test_edgeCase_MinAndMaxTogether() public {
        int24 minTick = -887272;
        int24 maxTick = 887272;

        harness.insertTick(minTick);
        harness.insertTick(maxTick);

        assertEq(harness.minActiveTick(), minTick);
        assertEq(harness.maxActiveTick(), maxTick);
        assertEq(harness.activeTickCount(), 2);

        // Should be able to find max from min
        (int24 next, bool found) = harness.nextInitializedTick(minTick, false, maxTick + 1);
        assertTrue(found);
        assertEq(next, maxTick);
    }

    function test_edgeCase_AdjacentTicks() public {
        harness.insertTick(100);
        harness.insertTick(101);
        harness.insertTick(102);

        // Should correctly navigate adjacent ticks
        (int24 next, bool found) = harness.nextInitializedTick(99, false, 200);
        assertTrue(found);
        assertEq(next, 100);

        (next, found) = harness.nextInitializedTick(100, false, 200);
        assertTrue(found);
        assertEq(next, 101);

        (next, found) = harness.nextInitializedTick(101, false, 200);
        assertTrue(found);
        assertEq(next, 102);
    }

    function test_edgeCase_DenseWord() public {
        // Fill every tick in a word
        for (int24 i = 0; i < 256; i++) {
            harness.insertTick(i);
        }

        assertEq(harness.activeTickCount(), 256);

        // Should find correct tick from any position
        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(128, true);
        assertTrue(found);
        assertEq(next, 128);

        (next, found) = harness.nextInitializedTickWithinOneWord(127, false);
        assertTrue(found);
        assertEq(next, 128);
    }

    function test_edgeCase_SparseAcrossWords() public {
        // One tick per word across many words
        for (int24 i = 0; i < 10; i++) {
            harness.insertTick(i * 256 + 128);  // Middle of each word
        }

        assertEq(harness.activeTickCount(), 10);
        assertEq(harness.minActiveTick(), 128);
        assertEq(harness.maxActiveTick(), 9 * 256 + 128);

        // Should traverse all words correctly
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 3000);
        assertTrue(found);
        assertEq(next, 128);

        (next, found) = harness.nextInitializedTick(200, false, 3000);
        assertTrue(found);
        assertEq(next, 256 + 128);
    }

    function testFuzz_insertRemove_Roundtrip(int24 tick) public {
        // Bound to valid tick range
        tick = int24(bound(int256(tick), -887272, 887272));

        harness.insertTick(tick);
        assertTrue(harness.isTickActive(tick));
        assertEq(harness.activeTickCount(), 1);

        harness.removeTick(tick);
        assertFalse(harness.isTickActive(tick));
        assertEq(harness.activeTickCount(), 0);
    }

    function testFuzz_insertMultiple_MinMaxCorrect(int24[5] memory ticks) public {
        int24 expectedMin = type(int24).max;
        int24 expectedMax = type(int24).min;
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < 5; i++) {
            // Bound to valid range
            ticks[i] = int24(bound(int256(ticks[i]), -887272, 887272));
            
            // Check if already inserted
            if (!harness.isTickActive(ticks[i])) {
                harness.insertTick(ticks[i]);
                uniqueCount++;
            }

            if (ticks[i] < expectedMin) expectedMin = ticks[i];
            if (ticks[i] > expectedMax) expectedMax = ticks[i];
        }

        if (uniqueCount > 0) {
            assertEq(harness.minActiveTick(), expectedMin);
            assertEq(harness.maxActiveTick(), expectedMax);
            assertEq(harness.activeTickCount(), uniqueCount);
        }
    }

    function testFuzz_nextInitializedTick_FindsInserted(int24 tick, int24 startTick) public {
        // Bound inputs
        tick = int24(bound(int256(tick), -887272, 887272));
        startTick = int24(bound(int256(startTick), -887272, 887272));

        harness.insertTick(tick);

        if (startTick < tick) {
            // Search right from startTick
            (int24 next, bool found) = harness.nextInitializedTick(startTick, false, tick + 1);
            assertTrue(found, "Should find tick when searching right");
            assertEq(next, tick);
        } else if (startTick >= tick) {
            // Search left from startTick
            (int24 next, bool found) = harness.nextInitializedTick(startTick, true, tick - 1);
            assertTrue(found, "Should find tick when searching left");
            assertEq(next, tick);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: Bitmap Correctness Verification
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verify position() calculation is correct
    /// @dev Uses V3 style: wordPos = int16(tick >> 8), bitPos = uint8(tick % 256)
    function test_PositionCalculation_Correctness() public view {
        // Positive ticks
        _verifyPosition(0, 0, 0);
        _verifyPosition(1, 0, 1);
        _verifyPosition(255, 0, 255);
        _verifyPosition(256, 1, 0);
        
        // Negative ticks (signed arithmetic)
        _verifyPosition(-1, -1, 255);
        _verifyPosition(-256, -1, 0);
        _verifyPosition(-257, -2, 255);
    }

    function _verifyPosition(int24 tick, int16 expectedWord, uint8 expectedBit) internal view {
        (int16 wordPos, uint8 bitPos) = harness.position(tick);
        assertEq(wordPos, expectedWord, "Word position mismatch");
        assertEq(bitPos, expectedBit, "Bit position mismatch");
    }

    /// @notice Verify mask calculation for lte=true
    function test_MaskCalculation_LTE() public pure {
        // V3 style: mask = (1 << bitPos) - 1 + (1 << bitPos)
        // This creates a mask with all 1s at or to the right of bitPos
        
        uint8 bitPos = 100;
        uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
        
        // Should have 101 bits set (0 through 100)
        uint256 expectedMask = (1 << 101) - 1;
        assertEq(mask, expectedMask, "LTE mask calculation incorrect");
    }

    /// @notice Verify mask calculation for lte=false
    function test_MaskCalculation_GTE() public pure {
        // mask = ~((1 << bitPos) - 1)
        // This creates a mask with all 1s at or to the left of bitPos
        
        uint8 bitPos = 100;
        uint256 mask = ~((1 << bitPos) - 1);
        
        // Should have bits 100-255 set
        uint256 expectedMask = type(uint256).max << 100;
        assertEq(mask, expectedMask, "GTE mask calculation incorrect");
    }
}
