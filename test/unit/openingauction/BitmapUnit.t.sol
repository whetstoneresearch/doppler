// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";

/// @title OpeningAuctionBitmapHarness
/// @notice Exposes OpeningAuction's internal bitmap functions for unit testing
/// @dev Inherits from OpeningAuction to test the ACTUAL production code
contract OpeningAuctionBitmapHarness is OpeningAuctionTestCompat {
    /// @notice Track liquidity for insert/remove logic (mirrors production)
    /// @dev We need to access liquidityAtTick but it's already in OpeningAuction

    /// @notice The tick spacing used for tests (set in constructor)
    int24 public testTickSpacing;

    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config
    ) OpeningAuctionTestCompat(poolManager_, initializer_, totalAuctionTokens_, config) {
        testTickSpacing = config.tickSpacing;
        // Set poolKey.tickSpacing for _compressTick/_decompressTick to work
        // We're using a minimal poolKey just for bitmap tests
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /// @notice Override to bypass hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {}

    // ============ Exposed Bitmap Functions (testing production code) ============

    /// @notice Exposes _position for testing
    /// @dev Takes a COMPRESSED tick (as production code expects)
    function position(int24 compressedTick) public pure returns (int16 wordPos, uint8 bitPos) {
        return _position(compressedTick);
    }

    /// @notice Exposes _flipTickCompressed for testing
    function flipTickCompressed(int24 compressedTick) public {
        _flipTickCompressed(compressedTick);
    }

    /// @notice Exposes _isCompressedTickActive for testing
    function isCompressedTickActive(int24 compressedTick) public view returns (bool) {
        return _isCompressedTickActive(compressedTick);
    }

    /// @notice Exposes _nextInitializedTickWithinOneWord for testing
    /// @dev Takes and returns COMPRESSED ticks (as production code does)
    function nextInitializedTickWithinOneWord(int24 compressedTick, bool lte)
        public
        view
        returns (int24 next, bool initialized)
    {
        return _nextInitializedTickWithinOneWord(compressedTick, lte);
    }

    /// @notice Exposes _nextInitializedTick for testing
    /// @dev Takes and returns COMPRESSED ticks (as production code does)
    function nextInitializedTick(int24 compressedTick, bool lte, int24 boundCompressedTick)
        public
        view
        returns (int24 next, bool found)
    {
        return _nextInitializedTick(compressedTick, lte, boundCompressedTick);
    }

    /// @notice Exposes _compressTick for testing
    function compressTick(int24 tick) public view returns (int24) {
        return _compressTick(tick);
    }

    /// @notice Exposes _decompressTick for testing
    function decompressTick(int24 compressedTick) public view returns (int24) {
        return _decompressTick(compressedTick);
    }

    /// @notice Insert a tick into the bitmap (production behavior)
    /// @dev Takes an UNCOMPRESSED tick (real tick value)
    function insertTick(int24 tick) public {
        _insertTick(tick);
        // Also set liquidity to mark as active (production does this too)
        if (liquidityAtTick[tick] == 0) {
            liquidityAtTick[tick] = 1;
        }
    }

    /// @notice Remove a tick from the bitmap (production behavior)
    /// @dev Takes an UNCOMPRESSED tick (real tick value)
    function removeTick(int24 tick) public {
        // Clear liquidity first
        liquidityAtTick[tick] = 0;
        _removeTick(tick);
    }

    /// @notice Check if a tick is active (using real tick)
    function isTickActive(int24 tick) public view returns (bool) {
        int24 compressed = _compressTick(tick);
        return _isCompressedTickActive(compressed);
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

    /// @notice Get min active tick (compressed)
    function getMinActiveTick() public view returns (int24) {
        return minActiveTick;
    }

    /// @notice Get max active tick (compressed)
    function getMaxActiveTick() public view returns (int24) {
        return maxActiveTick;
    }

    /// @notice Check if there are active ticks
    function getHasActiveTicks() public view returns (bool) {
        return hasActiveTicks;
    }

    /// @notice Get active tick count
    function getActiveTickCount() public view returns (uint256) {
        return activeTickCount;
    }

    // ============ Walk Helpers (mimic OpeningAuction iteration patterns) ============

    /// @notice Walk active ticks between [startCompressed, endCompressed] inclusive
    /// @dev Mimics OpeningAuction._walkTicksRange iteration pattern:
    ///      iterTick starts at startCompressed; then calls nextInitializedTick(iterTick-1, lte=false, bound=end+1)
    ///      and advances iterTick = nextCompressed + 1.
    /// @param startCompressed Inclusive start (compressed tick)
    /// @param endCompressed Inclusive end (compressed tick)
    /// @param maxOut Safety cap to avoid runaway; must be >= expected count
    function walkPatternA(int24 startCompressed, int24 endCompressed, uint256 maxOut)
        public
        view
        returns (int24[] memory out, uint256 outLen)
    {
        out = new int24[](maxOut);
        int24 iterTick = startCompressed;
        while (iterTick <= endCompressed) {
            (int24 nextCompressed, bool found) = _nextInitializedTick(
                iterTick - 1,
                false,
                endCompressed + 1
            );
            if (!found) break;

            if (nextCompressed > endCompressed) break;

            if (outLen >= maxOut) revert("walk overflow");
            out[outLen++] = nextCompressed;

            iterTick = nextCompressed + 1;
        }
    }

    /// @notice Alternative walk pattern: iterTick = nextCompressed (reviewer suggestion)
    /// @dev Included to demonstrate potential duplicates/infinite loops if used incorrectly.
    function walkPatternB(int24 startCompressed, int24 endCompressed, uint256 maxOut)
        public
        view
        returns (int24[] memory out, uint256 outLen)
    {
        out = new int24[](maxOut);
        int24 iterTick = startCompressed;
        while (iterTick <= endCompressed) {
            (int24 nextCompressed, bool found) = _nextInitializedTick(
                iterTick - 1,
                false,
                endCompressed + 1
            );
            if (!found) break;

            if (nextCompressed > endCompressed) break;

            if (outLen >= maxOut) revert("walk overflow");
            out[outLen++] = nextCompressed;

            iterTick = nextCompressed; // differs - doesn't advance past found tick
        }
    }
}

/// @title BitmapUnitTest
/// @notice Comprehensive unit tests for OpeningAuction bitmap implementation
/// @dev Tests the ACTUAL production bitmap functions via harness inheritance
contract BitmapUnitTest is Test {
    OpeningAuctionBitmapHarness harness;
    IPoolManager poolManager;

    // Default tick spacing for tests
    int24 constant DEFAULT_TICK_SPACING = 1;

    function setUp() public {
        // Deploy a minimal pool manager (we don't actually use it for bitmap tests)
        poolManager = new PoolManager(address(this));

        // Create harness with tick spacing = 1 (identity compression)
        harness = _createHarness(DEFAULT_TICK_SPACING);
    }

    function _createHarness(int24 tickSpacing) internal returns (OpeningAuctionBitmapHarness) {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: TickMath.MIN_TICK - (TickMath.MIN_TICK % tickSpacing),
            minAcceptableTickToken1: TickMath.MAX_TICK - (TickMath.MAX_TICK % tickSpacing),
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1,
            shareToAuctionBps: 5000
        });

        return new OpeningAuctionBitmapHarness(
            poolManager,
            address(this), // initializer
            1000 ether,    // totalAuctionTokens
            config
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: _position() Tests (COMPRESSED ticks)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_position_Zero() public view {
        (int16 wordPos, uint8 bitPos) = harness.position(0);
        assertEq(wordPos, 0, "compressed tick 0 should be in word 0");
        assertEq(bitPos, 0, "compressed tick 0 should be at bit 0");
    }

    function test_position_PositiveSmall() public view {
        // Compressed tick 1 should be word 0, bit 1
        (int16 wordPos, uint8 bitPos) = harness.position(1);
        assertEq(wordPos, 0);
        assertEq(bitPos, 1);

        // Compressed tick 127 should be word 0, bit 127
        (wordPos, bitPos) = harness.position(127);
        assertEq(wordPos, 0);
        assertEq(bitPos, 127);

        // Compressed tick 255 should be word 0, bit 255
        (wordPos, bitPos) = harness.position(255);
        assertEq(wordPos, 0);
        assertEq(bitPos, 255);
    }

    function test_position_PositiveWordBoundary() public view {
        // Compressed tick 256 should be word 1, bit 0 (first tick of next word)
        (int16 wordPos, uint8 bitPos) = harness.position(256);
        assertEq(wordPos, 1, "compressed tick 256 should be in word 1");
        assertEq(bitPos, 0, "compressed tick 256 should be at bit 0");

        // Compressed tick 257 should be word 1, bit 1
        (wordPos, bitPos) = harness.position(257);
        assertEq(wordPos, 1);
        assertEq(bitPos, 1);

        // Compressed tick 511 should be word 1, bit 255
        (wordPos, bitPos) = harness.position(511);
        assertEq(wordPos, 1);
        assertEq(bitPos, 255);

        // Compressed tick 512 should be word 2, bit 0
        (wordPos, bitPos) = harness.position(512);
        assertEq(wordPos, 2);
        assertEq(bitPos, 0);
    }

    function test_position_NegativeSmall() public view {
        // Compressed tick -1 should be word -1, bit 255
        (int16 wordPos, uint8 bitPos) = harness.position(-1);
        assertEq(wordPos, -1, "compressed tick -1 should be in word -1");
        assertEq(bitPos, 255, "compressed tick -1 should be at bit 255");

        // Compressed tick -2 should be word -1, bit 254
        (wordPos, bitPos) = harness.position(-2);
        assertEq(wordPos, -1);
        assertEq(bitPos, 254);

        // Compressed tick -128 should be word -1, bit 128
        (wordPos, bitPos) = harness.position(-128);
        assertEq(wordPos, -1);
        assertEq(bitPos, 128);

        // Compressed tick -255 should be word -1, bit 1
        (wordPos, bitPos) = harness.position(-255);
        assertEq(wordPos, -1);
        assertEq(bitPos, 1);

        // Compressed tick -256 should be word -1, bit 0
        (wordPos, bitPos) = harness.position(-256);
        assertEq(wordPos, -1);
        assertEq(bitPos, 0);
    }

    function test_position_NegativeWordBoundary() public view {
        // Compressed tick -257 should be word -2, bit 255
        (int16 wordPos, uint8 bitPos) = harness.position(-257);
        assertEq(wordPos, -2, "compressed tick -257 should be in word -2");
        assertEq(bitPos, 255, "compressed tick -257 should be at bit 255");

        // Compressed tick -512 should be word -2, bit 0
        (wordPos, bitPos) = harness.position(-512);
        assertEq(wordPos, -2);
        assertEq(bitPos, 0);

        // Compressed tick -513 should be word -3, bit 255
        (wordPos, bitPos) = harness.position(-513);
        assertEq(wordPos, -3);
        assertEq(bitPos, 255);
    }

    function test_position_LargePositive() public view {
        // Compressed tick 10000: 10000 / 256 = 39, 10000 % 256 = 16
        (int16 wordPos, uint8 bitPos) = harness.position(10000);
        assertEq(wordPos, 39);
        assertEq(bitPos, 16);
    }

    function test_position_LargeNegative() public view {
        // Compressed tick -10000: floor(-10000 / 256) = -40, -10000 & 0xff = 240
        (int16 wordPos, uint8 bitPos) = harness.position(-10000);
        assertEq(wordPos, -40);
        assertEq(bitPos, 240);
    }

    function testFuzz_position_Roundtrip(int24 compressedTick) public view {
        // Bound to reasonable range
        compressedTick = int24(bound(int256(compressedTick), -32768, 32767));

        // Verify that position gives consistent results
        (int16 wordPos, uint8 bitPos) = harness.position(compressedTick);

        // Reconstruct tick from wordPos and bitPos
        int24 reconstructed = int24(wordPos) * 256 + int24(uint24(bitPos));
        assertEq(reconstructed, compressedTick, "position should roundtrip correctly");
    }

    function testFuzz_position_BitPosRange(int24 compressedTick) public view {
        compressedTick = int24(bound(int256(compressedTick), -32768, 32767));
        (, uint8 bitPos) = harness.position(compressedTick);
        assertTrue(bitPos < 256, "bitPos should always be < 256");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: flipTickCompressed and isCompressedTickActive Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_flipTick_SetAndUnset() public {
        int24 compressedTick = 100;

        // Initially not active
        assertFalse(harness.isCompressedTickActive(compressedTick), "tick should start inactive");

        // Flip once - should be active
        harness.flipTickCompressed(compressedTick);
        assertTrue(harness.isCompressedTickActive(compressedTick), "tick should be active after first flip");

        // Flip again - should be inactive
        harness.flipTickCompressed(compressedTick);
        assertFalse(harness.isCompressedTickActive(compressedTick), "tick should be inactive after second flip");
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
            harness.flipTickCompressed(ticks[i]);
        }

        // Verify all are active
        for (uint256 i = 0; i < ticks.length; i++) {
            assertTrue(harness.isCompressedTickActive(ticks[i]), "tick should be active");
        }

        // Verify word has correct bits set
        uint256 expectedWord = (1 << 0) | (1 << 50) | (1 << 100) | (1 << 150) | (1 << 255);
        assertEq(harness.getWord(0), expectedWord, "word should have correct bits");
    }

    function test_flipTick_DifferentWords() public {
        // Compressed ticks in different words
        int24[] memory ticks = new int24[](4);
        ticks[0] = 0;      // word 0
        ticks[1] = 256;    // word 1
        ticks[2] = -1;     // word -1
        ticks[3] = -257;   // word -2

        for (uint256 i = 0; i < ticks.length; i++) {
            harness.flipTickCompressed(ticks[i]);
        }

        // Verify all are active
        for (uint256 i = 0; i < ticks.length; i++) {
            assertTrue(harness.isCompressedTickActive(ticks[i]), "tick should be active");
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
            harness.flipTickCompressed(ticks[i]);
            assertTrue(harness.isCompressedTickActive(ticks[i]), "negative tick should be active after flip");
        }
    }

    function testFuzz_flipTick_Idempotent(int24 compressedTick) public {
        compressedTick = int24(bound(int256(compressedTick), -32768, 32767));

        // Double flip should return to original state
        bool stateBefore = harness.isCompressedTickActive(compressedTick);
        harness.flipTickCompressed(compressedTick);
        harness.flipTickCompressed(compressedTick);
        bool stateAfter = harness.isCompressedTickActive(compressedTick);
        assertEq(stateBefore, stateAfter, "double flip should be idempotent");
    }

    function testFuzz_flipTick_Independent(int24 tick1, int24 tick2) public {
        tick1 = int24(bound(int256(tick1), -32768, 32767));
        tick2 = int24(bound(int256(tick2), -32768, 32767));
        vm.assume(tick1 != tick2);

        harness.flipTickCompressed(tick1);
        assertTrue(harness.isCompressedTickActive(tick1));
        assertFalse(harness.isCompressedTickActive(tick2));

        harness.flipTickCompressed(tick2);
        assertTrue(harness.isCompressedTickActive(tick1));
        assertTrue(harness.isCompressedTickActive(tick2));

        harness.flipTickCompressed(tick1);
        assertFalse(harness.isCompressedTickActive(tick1));
        assertTrue(harness.isCompressedTickActive(tick2));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: _nextInitializedTickWithinOneWord() Tests (COMPRESSED ticks)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTickWithinOneWord_LTE_SingleTick() public {
        harness.flipTickCompressed(100);

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
        harness.flipTickCompressed(100);

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
        // next should be at last tick in word (255)
        assertEq(next, 255);
    }

    function test_nextInitializedTickWithinOneWord_LTE_MultipleTicks() public {
        harness.flipTickCompressed(50);
        harness.flipTickCompressed(100);
        harness.flipTickCompressed(200);

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
        harness.flipTickCompressed(50);
        harness.flipTickCompressed(100);
        harness.flipTickCompressed(200);

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
        // Negative compressed ticks are in word -1
        harness.flipTickCompressed(-50);
        harness.flipTickCompressed(-100);
        harness.flipTickCompressed(-200);

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
        harness.flipTickCompressed(-50);
        harness.flipTickCompressed(-100);
        harness.flipTickCompressed(-200);

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
        harness.flipTickCompressed(0);

        (int24 next, bool found) = harness.nextInitializedTickWithinOneWord(100, true);
        assertTrue(found);
        assertEq(next, 0);

        // Tick at bit 255 of word 0
        harness.flipTickCompressed(255);

        (next, found) = harness.nextInitializedTickWithinOneWord(200, false);
        assertTrue(found);
        assertEq(next, 255);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: _nextInitializedTick() Cross-Word Tests (COMPRESSED ticks)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTick_CrossWord_GTE() public {
        // Set compressed tick in word 2 (tick 512)
        harness.flipTickCompressed(512);

        // Search from compressed tick 0 going right with bound at 1000
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 1000);
        assertTrue(found);
        assertEq(next, 512);
    }

    function test_nextInitializedTick_CrossWord_LTE() public {
        // Set compressed tick in word -2 (tick -300)
        harness.flipTickCompressed(-300);

        // Search from compressed tick 0 going left with bound at -500
        (int24 next, bool found) = harness.nextInitializedTick(0, true, -500);
        assertTrue(found);
        assertEq(next, -300);
    }

    function test_nextInitializedTick_MultipleWords_FindClosest() public {
        harness.flipTickCompressed(100);    // word 0
        harness.flipTickCompressed(300);    // word 1
        harness.flipTickCompressed(600);    // word 2

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
        harness.flipTickCompressed(1000);

        // Search with bound before the tick
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 500);
        assertFalse(found);
        assertEq(next, 500); // Returns bound
    }

    function test_nextInitializedTick_HitsBound_LTE() public {
        harness.flipTickCompressed(-1000);

        // Search with bound after the tick
        (int24 next, bool found) = harness.nextInitializedTick(0, true, -500);
        assertFalse(found);
        assertEq(next, -500); // Returns bound
    }

    function test_nextInitializedTick_NoTicksInRange() public view {
        // No ticks set at all
        (int24 next, bool found) = harness.nextInitializedTick(0, false, 10000);
        assertFalse(found);
        assertEq(next, 10000);

        (next, found) = harness.nextInitializedTick(0, true, -10000);
        assertFalse(found);
        assertEq(next, -10000);
    }

    function test_nextInitializedTick_LargeGap() public {
        // Set compressed ticks with large gap (many empty words between)
        harness.flipTickCompressed(0);
        harness.flipTickCompressed(10000);  // ~39 words apart

        // Should still find it
        (int24 next, bool found) = harness.nextInitializedTick(100, false, 20000);
        assertTrue(found);
        assertEq(next, 10000);
    }

    function test_nextInitializedTick_ExactMatch() public {
        harness.flipTickCompressed(500);

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
    // SECTION 5: _insertTick() and _removeTick() Tests (real ticks)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_insertTick_Basic() public {
        assertFalse(harness.getHasActiveTicks());
        assertEq(harness.getActiveTickCount(), 0);

        harness.insertTick(100);

        assertTrue(harness.getHasActiveTicks());
        assertEq(harness.getActiveTickCount(), 1);
        assertTrue(harness.isTickActive(100));
        assertEq(harness.getMinActiveTick(), 100); // compressed = 100 with tickSpacing=1
        assertEq(harness.getMaxActiveTick(), 100);
    }

    function test_insertTick_UpdatesMinMax() public {
        harness.insertTick(100);
        assertEq(harness.getMinActiveTick(), 100);
        assertEq(harness.getMaxActiveTick(), 100);

        harness.insertTick(50);
        assertEq(harness.getMinActiveTick(), 50);
        assertEq(harness.getMaxActiveTick(), 100);

        harness.insertTick(200);
        assertEq(harness.getMinActiveTick(), 50);
        assertEq(harness.getMaxActiveTick(), 200);

        harness.insertTick(75);  // Between min and max - no change
        assertEq(harness.getMinActiveTick(), 50);
        assertEq(harness.getMaxActiveTick(), 200);
    }

    function test_insertTick_Duplicate() public {
        harness.insertTick(100);
        assertEq(harness.getActiveTickCount(), 1);

        // Insert same tick again - should be no-op
        harness.insertTick(100);
        assertEq(harness.getActiveTickCount(), 1);
        assertTrue(harness.isTickActive(100));
    }

    function test_insertTick_NegativeTicks() public {
        harness.insertTick(-100);
        assertEq(harness.getMinActiveTick(), -100);
        assertEq(harness.getMaxActiveTick(), -100);

        harness.insertTick(-200);
        assertEq(harness.getMinActiveTick(), -200);
        assertEq(harness.getMaxActiveTick(), -100);

        harness.insertTick(50);
        assertEq(harness.getMinActiveTick(), -200);
        assertEq(harness.getMaxActiveTick(), 50);
    }

    function test_removeTick_Basic() public {
        harness.insertTick(100);
        assertTrue(harness.isTickActive(100));

        harness.removeTick(100);
        assertFalse(harness.isTickActive(100));
        assertFalse(harness.getHasActiveTicks());
        assertEq(harness.getActiveTickCount(), 0);
    }

    function test_removeTick_UpdatesMin() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        assertEq(harness.getMinActiveTick(), 50);

        // Remove min - should update to next tick
        harness.removeTick(50);
        assertEq(harness.getMinActiveTick(), 100);
        assertEq(harness.getActiveTickCount(), 2);
    }

    function test_removeTick_UpdatesMax() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        assertEq(harness.getMaxActiveTick(), 150);

        // Remove max - should update to previous tick
        harness.removeTick(150);
        assertEq(harness.getMaxActiveTick(), 100);
        assertEq(harness.getActiveTickCount(), 2);
    }

    function test_removeTick_MiddleTick() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        // Remove middle tick - min/max unchanged
        harness.removeTick(100);
        assertEq(harness.getMinActiveTick(), 50);
        assertEq(harness.getMaxActiveTick(), 150);
        assertEq(harness.getActiveTickCount(), 2);
    }

    function test_removeTick_NonExistent() public {
        harness.insertTick(100);
        assertEq(harness.getActiveTickCount(), 1);

        // Remove non-existent tick - should be no-op
        harness.removeTick(200);
        assertEq(harness.getActiveTickCount(), 1);
        assertTrue(harness.isTickActive(100));
    }

    function test_removeTick_AllTicks() public {
        harness.insertTick(50);
        harness.insertTick(100);
        harness.insertTick(150);

        harness.removeTick(50);
        harness.removeTick(100);
        harness.removeTick(150);

        assertFalse(harness.getHasActiveTicks());
        assertEq(harness.getActiveTickCount(), 0);
    }

    function test_removeTick_CrossWord() public {
        // Insert ticks across multiple words
        harness.insertTick(0);      // word 0
        harness.insertTick(300);    // word 1
        harness.insertTick(600);    // word 2

        assertEq(harness.getMinActiveTick(), 0);
        assertEq(harness.getMaxActiveTick(), 600);

        // Remove min - should find 300 as new min
        harness.removeTick(0);
        assertEq(harness.getMinActiveTick(), 300);

        // Remove max - should find 300 as new max
        harness.removeTick(600);
        assertEq(harness.getMaxActiveTick(), 300);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: Edge Cases and Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_edgeCase_MaxTick() public {
        int24 maxTick = 887272;  // Near TickMath.MAX_TICK

        harness.insertTick(maxTick);
        assertTrue(harness.isTickActive(maxTick));
        assertEq(harness.getMaxActiveTick(), maxTick);
    }

    function test_edgeCase_MinTick() public {
        int24 minTick = -887272;  // Near TickMath.MIN_TICK

        harness.insertTick(minTick);
        assertTrue(harness.isTickActive(minTick));
        assertEq(harness.getMinActiveTick(), minTick);
    }

    function test_edgeCase_MinAndMaxTogether() public {
        int24 minTick = -887272;
        int24 maxTick = 887272;

        harness.insertTick(minTick);
        harness.insertTick(maxTick);

        assertEq(harness.getMinActiveTick(), minTick);
        assertEq(harness.getMaxActiveTick(), maxTick);
        assertEq(harness.getActiveTickCount(), 2);

        // Should be able to find max from min (using compressed ticks)
        (int24 next, bool found) = harness.nextInitializedTick(minTick, false, maxTick + 1);
        assertTrue(found);
        assertEq(next, maxTick);
    }

    function test_edgeCase_AdjacentTicks() public {
        harness.insertTick(100);
        harness.insertTick(101);
        harness.insertTick(102);

        // Should correctly navigate adjacent ticks (using compressed values = same as real with tickSpacing=1)
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
        // Fill every tick in a word (compressed ticks 0-255)
        for (int24 i = 0; i < 256; i++) {
            harness.insertTick(i);
        }

        assertEq(harness.getActiveTickCount(), 256);

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

        assertEq(harness.getActiveTickCount(), 10);
        assertEq(harness.getMinActiveTick(), 128);
        assertEq(harness.getMaxActiveTick(), 9 * 256 + 128);

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
        assertEq(harness.getActiveTickCount(), 1);

        harness.removeTick(tick);
        assertFalse(harness.isTickActive(tick));
        assertEq(harness.getActiveTickCount(), 0);
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
            assertEq(harness.getMinActiveTick(), expectedMin);
            assertEq(harness.getMaxActiveTick(), expectedMax);
            assertEq(harness.getActiveTickCount(), uniqueCount);
        }
    }

    function testFuzz_nextInitializedTick_FindsInserted(int24 tick, int24 startTick) public {
        // Bound inputs
        tick = int24(bound(int256(tick), -887272, 887272));
        startTick = int24(bound(int256(startTick), -887272, 887272));

        harness.insertTick(tick);
        int24 compressedTick = harness.compressTick(tick);
        int24 compressedStart = harness.compressTick(startTick);

        if (compressedStart < compressedTick) {
            // Search right from startTick (compressed)
            (int24 next, bool found) = harness.nextInitializedTick(compressedStart, false, compressedTick + 1);
            assertTrue(found, "Should find tick when searching right");
            assertEq(next, compressedTick);
        } else if (compressedStart >= compressedTick) {
            // Search left from startTick (compressed)
            (int24 next, bool found) = harness.nextInitializedTick(compressedStart, true, compressedTick - 1);
            assertTrue(found, "Should find tick when searching left");
            assertEq(next, compressedTick);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: Bitmap Correctness Verification
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verify position() calculation is correct for compressed ticks
    function test_PositionCalculation_Correctness() public view {
        // Positive compressed ticks
        _verifyPosition(0, 0, 0);
        _verifyPosition(1, 0, 1);
        _verifyPosition(255, 0, 255);
        _verifyPosition(256, 1, 0);

        // Negative compressed ticks (signed arithmetic)
        _verifyPosition(-1, -1, 255);
        _verifyPosition(-256, -1, 0);
        _verifyPosition(-257, -2, 255);
    }

    function _verifyPosition(int24 compressedTick, int16 expectedWord, uint8 expectedBit) internal view {
        (int16 wordPos, uint8 bitPos) = harness.position(compressedTick);
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

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: Tick-walk iteration regression tests (skip/duplicate detection)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_walkPatternA_NoSkip_ConsecutiveCompressedTicks() public {
        // Insert ticks whose compressed values are consecutive: 0,1,2,3
        harness.insertTick(0);
        harness.insertTick(1);
        harness.insertTick(2);
        harness.insertTick(3);

        (int24[] memory out, uint256 len) = harness.walkPatternA(0, 3, 16);
        assertEq(len, 4, "should visit all 4 ticks");
        assertEq(out[0], 0);
        assertEq(out[1], 1);
        assertEq(out[2], 2);
        assertEq(out[3], 3);
    }

    function test_walkPatternA_NoSkip_SparseAndEdges() public {
        // compressed ticks: -2, 0, 5, 255, 256
        harness.insertTick(-2);
        harness.insertTick(0);
        harness.insertTick(5);
        harness.insertTick(255);
        harness.insertTick(256); // word boundary

        (int24[] memory out, uint256 len) = harness.walkPatternA(-5, 300, 32);
        // expected visited compressed within bounds
        int24[] memory exp = new int24[](5);
        exp[0] = -2;
        exp[1] = 0;
        exp[2] = 5;
        exp[3] = 255;
        exp[4] = 256;
        assertEq(len, exp.length);
        for (uint256 i = 0; i < len; i++) {
            assertEq(out[i], exp[i]);
        }
    }

    function test_walkPatternB_DemonstratesDuplicateRisk() public {
        harness.insertTick(0);
        harness.insertTick(1);

        // PatternB does not advance past nextCompressed and can loop.
        // Our harness guards with a maxOut cap and reverts with "walk overflow".
        vm.expectRevert(bytes("walk overflow"));
        harness.walkPatternB(0, 1, 4);
    }

    function testFuzz_walkPatternA_VisitsExactlyActiveTicks(int256 seed) public {
        // Bounded compressed range [-32, 32]
        int24 minC = -32;
        int24 maxC = 32;

        // Build a pseudo-random set of active ticks from seed (no external RNG)
        // Use a 65-bit bitmap in memory (uint256) for expected membership.
        uint256 expectedMask = 0;
        for (int24 c = minC; c <= maxC; c++) {
            // simple hash: mix seed and c
            uint256 h = uint256(keccak256(abi.encode(seed, c)));
            bool take = (h & 7) == 0; // ~1/8 density
            if (take) {
                harness.insertTick(c); // tickSpacing=1 => tick==compressed
                expectedMask |= (1 << uint24(uint24(int24(c - minC))));
            }
        }

        (int24[] memory out, uint256 len) = harness.walkPatternA(minC, maxC, 128);

        // 1) ensure strictly increasing and within bounds
        for (uint256 i = 0; i < len; i++) {
            assertTrue(out[i] >= minC && out[i] <= maxC, "out of bounds");
            if (i > 0) assertTrue(out[i] > out[i - 1], "not strictly increasing");
        }

        // 2) ensure visited set equals expected set
        uint256 seenMask = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 bit = 1 << uint24(uint24(int24(out[i] - minC)));
            seenMask |= bit;
            assertTrue((expectedMask & bit) != 0, "visited tick not expected");
        }
        // every expected tick should have been seen
        assertEq(seenMask, expectedMask, "mismatch: skip or missing tick");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 9: Tests with non-trivial tick spacing
    // ═══════════════════════════════════════════════════════════════════════════

    function test_tickSpacing60_compression() public {
        // Create a harness with tick spacing 60
        OpeningAuctionBitmapHarness harness60 = _createHarness(60);

        // Verify tick compression
        assertEq(harness60.compressTick(0), 0);
        assertEq(harness60.compressTick(60), 1);
        assertEq(harness60.compressTick(120), 2);
        assertEq(harness60.compressTick(180), 3);

        // Negative tick compression (rounds toward negative infinity)
        assertEq(harness60.compressTick(-60), -1);
        assertEq(harness60.compressTick(-120), -2);
        assertEq(harness60.compressTick(-59), -1); // -59/60 = 0, but tick < 0 and remainder != 0, so -1
    }

    function test_tickSpacing60_insertAndNavigate() public {
        OpeningAuctionBitmapHarness harness60 = _createHarness(60);

        // Insert ticks at 0, 60, 120, 180 (compressed: 0, 1, 2, 3)
        harness60.insertTick(0);
        harness60.insertTick(60);
        harness60.insertTick(120);
        harness60.insertTick(180);

        assertEq(harness60.getActiveTickCount(), 4);
        assertEq(harness60.getMinActiveTick(), 0); // compressed
        assertEq(harness60.getMaxActiveTick(), 3); // compressed

        // Navigate using compressed ticks
        (int24 next, bool found) = harness60.nextInitializedTick(0, false, 10);
        assertTrue(found);
        assertEq(next, 1); // compressed tick 1 = real tick 60

        (next, found) = harness60.nextInitializedTick(1, false, 10);
        assertTrue(found);
        assertEq(next, 2); // compressed tick 2 = real tick 120
    }

    function test_tickSpacing60_walkPattern() public {
        OpeningAuctionBitmapHarness harness60 = _createHarness(60);

        // Insert ticks: 0, 60, 120, 180 (compressed: 0, 1, 2, 3)
        harness60.insertTick(0);
        harness60.insertTick(60);
        harness60.insertTick(120);
        harness60.insertTick(180);

        (int24[] memory out, uint256 len) = harness60.walkPatternA(0, 3, 16);
        assertEq(len, 4, "should visit all 4 compressed ticks");
        assertEq(out[0], 0);
        assertEq(out[1], 1);
        assertEq(out[2], 2);
        assertEq(out[3], 3);
    }

    function test_tickSpacing60_wordBoundary() public {
        OpeningAuctionBitmapHarness harness60 = _createHarness(60);

        // Compressed tick 255 = real tick 15300, compressed tick 256 = real tick 15360
        harness60.insertTick(15300); // compressed 255, end of word 0
        harness60.insertTick(15360); // compressed 256, start of word 1

        assertEq(harness60.compressTick(15300), 255);
        assertEq(harness60.compressTick(15360), 256);

        // Should find across word boundary
        (int24 next, bool found) = harness60.nextInitializedTick(255, false, 300);
        assertTrue(found);
        assertEq(next, 256);
    }
}
