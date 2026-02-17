// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

/// @notice Minimal harness to exercise the *real* OpeningAuction bitmap walkers.
/// @dev Overrides hook-address validation for unit tests.
contract OpeningAuctionTickWalkHarness is OpeningAuctionTestCompat {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuctionTestCompat(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}

    // ---- Expose selected internal helpers for testing ----
    function __ceilToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return _ceilToSpacing(tick, spacing);
    }

    function __floorToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return _floorToSpacing(tick, spacing);
    }

    function __compressTick(int24 tick) external view returns (int24) {
        return _compressTick(tick);
    }

    function __nextInitializedTick(int24 tick, bool lte, int24 boundTick) external view returns (int24 next, bool found) {
        return _nextInitializedTick(tick, lte, boundTick);
    }

    function __minActiveCompressed() external view returns (int24) {
        return minActiveTick;
    }

    function __maxActiveCompressed() external view returns (int24) {
        return maxActiveTick;
    }

    // ---- State setup helpers ----
    function __setTickSpacing(int24 tickSpacing) external {
        poolKey.tickSpacing = tickSpacing;
    }

    function __insertTick(int24 tickLower) external {
        // mimic production: _insertTick checks liquidityAtTick[tick]==0
        _insertTick(tickLower);
        liquidityAtTick[tickLower] = 1;
    }

    function __walk(int24 startTick, int24 endTick, bool entering) external {
        _walkTicksRange(startTick, endTick, poolKey.tickSpacing, entering);
    }
}

contract TickWalkRangeUnitTest is Test {
    PoolManager manager;
    OpeningAuctionTickWalkHarness h;

    // event topics copied from IOpeningAuction
    bytes32 constant TICK_ENTERED = keccak256("TickEnteredRange(int24,uint128)");
    bytes32 constant TICK_EXITED = keccak256("TickExitedRange(int24,uint128)");

    // A helper “walker” that implements the reviewer-suggested iteration:
    // iterTick = nextCompressed (instead of nextCompressed + 1)
    function _walkPatternB(
        int24 startTick,
        int24 endTick,
        int24 tickSpacing,
        uint256 maxSteps
    ) internal view returns (int24[] memory out, uint256 outLen) {
        out = new int24[](maxSteps);

        int24 startAligned = h.__ceilToSpacing(startTick, tickSpacing);
        int24 endAligned = h.__floorToSpacing(endTick, tickSpacing);
        if (startAligned > endAligned) return (out, 0);

        int24 startCompressed = h.__compressTick(startAligned);
        int24 endCompressed = h.__compressTick(endAligned);

        // Clamp to active tick bounds (compressed)
        int24 minActive = h.__minActiveCompressed();
        int24 maxActive = h.__maxActiveCompressed();
        if (startCompressed < minActive) startCompressed = minActive;
        if (endCompressed > maxActive) endCompressed = maxActive;
        if (startCompressed > endCompressed) return (out, 0);

        int24 iterTick = startCompressed;
        while (iterTick <= endCompressed) {
            (int24 nextCompressed, bool found) = h.__nextInitializedTick(iterTick - 1, false, endCompressed + 1);
            if (!found || nextCompressed > endCompressed) break;

            if (outLen >= maxSteps) revert("patternB: no progress / too many steps");
            out[outLen++] = nextCompressed;

            iterTick = nextCompressed; // reviewer suggestion
        }

        return (out, outLen);
    }

    function setUp() public {
        manager = new PoolManager(address(this));

        OpeningAuctionConfig memory config = OpeningAuctionTestDefaults.defaultConfig(
            1 days,
            -99_960,
            -99_960,
            60
        );

        h = new OpeningAuctionTickWalkHarness(manager, address(this), 1e18, config);

        // Ensure tickSpacing is set even though we aren't running full pool initialization.
        h.__setTickSpacing(60);
    }

    function _decodeTickFromLog(Vm.Log memory log) internal pure returns (int24 tick) {
        // TickEnteredRange(int24 indexed tick, uint128 liquidity)
        // topic1 = indexed tick (as int24 sign-extended into 32 bytes)
        // data = abi.encode(uint128 liquidity)
        bytes32 t = log.topics[1];
        // Interpret as int256 then cast to int24 to preserve sign.
        tick = int24(int256(uint256(t)));
    }

    function _collectTicks(bytes32 sig) internal returns (int24[] memory ticks) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) n++;
        }
        ticks = new int24[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                ticks[j++] = _decodeTickFromLog(logs[i]);
            }
        }
    }

    function test_walkTicksRange_NoSkip_ConsecutiveCompressedTicks() public {
        // spacing 60; ticks are 0,60,120,180
        h.__insertTick(0);
        h.__insertTick(60);
        h.__insertTick(120);
        h.__insertTick(180);

        vm.recordLogs();
        h.__walk(0, 180, true);
        int24[] memory ticks = _collectTicks(TICK_ENTERED);

        assertEq(ticks.length, 4);
        assertEq(ticks[0], 0);
        assertEq(ticks[1], 60);
        assertEq(ticks[2], 120);
        assertEq(ticks[3], 180);
    }

    function test_walkTicksRange_NoSkip_WordBoundary() public {
        // compressed 255 and 256 with spacing 60
        h.__insertTick(255 * 60);
        h.__insertTick(256 * 60);

        vm.recordLogs();
        h.__walk(0, 30000, true);
        int24[] memory ticks = _collectTicks(TICK_ENTERED);

        assertEq(ticks.length, 2);
        assertEq(ticks[0], int24(255 * 60));
        assertEq(ticks[1], int24(256 * 60));
    }

    function test_walkTicksRange_ClampsToActiveBounds() public {
        // Active ticks only in [60, 180]. Walking a huge range should emit only these.
        h.__insertTick(60);
        h.__insertTick(180);

        vm.recordLogs();
        h.__walk(-1_000_000, 1_000_000, true);
        int24[] memory ticks = _collectTicks(TICK_ENTERED);

        assertEq(ticks.length, 2);
        assertEq(ticks[0], 60);
        assertEq(ticks[1], 180);
    }

    function test_walkTicksRange_HandlesUnalignedRangeAndNegativeTicks() public {
        // spacing 60; include negative ticks and unaligned start/end to exercise ceil/floor.
        // Insert ticks at -120, 0, 120
        h.__insertTick(-120);
        h.__insertTick(0);
        h.__insertTick(120);

        // start/end are intentionally unaligned.
        // With spacing=60: ceil(-119)=-60 and floor(121)=120, so -120 is *out of range*.
        vm.recordLogs();
        h.__walk(-119, 121, true);
        int24[] memory ticks = _collectTicks(TICK_ENTERED);

        assertEq(ticks.length, 2);
        assertEq(ticks[0], 0);
        assertEq(ticks[1], 120);
    }

    function testFuzz_walkTicksRange_VisitsExactlyInsertedTicks(int256 seed) public {
        h.__setTickSpacing(1);

        int24 minC = -32;
        int24 maxC = 32;

        // expected set of ticks in [-32,32]
        uint256 expectedMask;
        for (int24 c = minC; c <= maxC; c++) {
            uint256 r = uint256(keccak256(abi.encode(seed, c)));
            if ((r & 7) == 0) {
                h.__insertTick(c);
                expectedMask |= (1 << uint24(uint24(int24(c - minC))));
            }
        }

        vm.recordLogs();
        h.__walk(minC, maxC, true);
        int24[] memory ticks = _collectTicks(TICK_ENTERED);

        // Build seen mask and ensure sorted, in-bounds
        uint256 seenMask;
        for (uint256 i = 0; i < ticks.length; i++) {
            assertTrue(ticks[i] >= minC && ticks[i] <= maxC, "out of bounds");
            if (i > 0) assertTrue(ticks[i] > ticks[i - 1], "not strictly increasing");
            uint256 bit = 1 << uint24(uint24(int24(ticks[i] - minC)));
            seenMask |= bit;
            assertTrue((expectedMask & bit) != 0, "visited tick not expected");
        }
        assertEq(seenMask, expectedMask, "mismatch: skip or missing tick");
    }

    // --- Prove the reviewer-suggested fix (iterTick = nextCompressed) is wrong ---

    function test_patternB_WouldLoopOnFirstTick() public {
        // Insert two consecutive ticks.
        h.__insertTick(0);
        h.__insertTick(60);

        // PatternB doesn't advance; it will keep returning the first initialized tick.
        // We prove non-termination by using our maxSteps guard.
        vm.expectRevert(bytes("patternB: no progress / too many steps"));
        this._walkPatternB_public(0, 60, 60, 8);
    }

    function test_patternB_WouldLoopEvenWithSparseTicks() public {
        h.__insertTick(0);
        h.__insertTick(180);

        vm.expectRevert(bytes("patternB: no progress / too many steps"));
        this._walkPatternB_public(0, 180, 60, 8);
    }

    // Expose PatternB helper for external call
    function _walkPatternB_public(int24 startTick, int24 endTick, int24 tickSpacing, uint256 maxSteps)
        external
        view
        returns (int24[] memory out, uint256 outLen)
    {
        return _walkPatternB(startTick, endTick, tickSpacing, maxSteps);
    }
}
