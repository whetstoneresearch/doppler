// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import {
    FeeScheduleParams,
    FeeScheduleSet,
    FeeTooHigh,
    InvalidDurationBlocks,
    InvalidFeeRange,
    LinearDescendingFeeDopplerHook,
    MAX_LP_FEE,
    FeeUpdated
} from "src/dopplerHooks/LinearDescendingFeeDopplerHook.sol";

contract MockDynamicLPFeeUpdater {
    address public lastAsset;
    uint24 public lastFee;
    uint256 public updateCount;

    function updateDynamicLPFee(address asset, uint24 lpFee) external {
        lastAsset = asset;
        lastFee = lpFee;
        updateCount++;
    }
}

contract LinearDescendingFeeDopplerHookTest is Test {
    LinearDescendingFeeDopplerHook internal dopplerHook;
    MockDynamicLPFeeUpdater internal updater;

    address internal asset = makeAddr("asset");
    address internal numeraire = makeAddr("numeraire");
    PoolKey internal poolKey;

    function setUp() public {
        updater = new MockDynamicLPFeeUpdater();
        dopplerHook = new LinearDescendingFeeDopplerHook(address(updater));

        poolKey = PoolKey({
            currency0: Currency.wrap(asset),
            currency1: Currency.wrap(numeraire),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(0))
        });
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dopplerHook.INITIALIZER(), address(updater));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_RevertsWhenSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 100)));
    }

    function test_onInitialization_RevertsWhenStartFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(MAX_LP_FEE + 1, 0, 100)));
    }

    function test_onInitialization_RevertsWhenEndFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, MAX_LP_FEE + 1, 100)));
    }

    function test_onInitialization_RevertsWhenFeeRangeAscending() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRange.selector, 1_000, 10_000));
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(1_000, 10_000, 100)));
    }

    function test_onInitialization_RevertsWhenDurationIsZeroForDescending() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDurationBlocks.selector, 0));
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 0)));
    }

    function test_onInitialization_StoresScheduleAndEmitsEvent() public {
        PoolId poolId = poolKey.toId();
        vm.expectEmit();
        emit FeeScheduleSet(poolId, asset, 10_000, 1_000, uint64(block.number), 100);

        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 100)));

        (
            address storedAsset,
            uint24 startFee,
            uint24 endFee,
            uint24 lastFee,
            uint64 startBlock,
            uint64 durationBlocks,
            bool enabled
        ) = dopplerHook.getFeeScheduleOf(poolId);

        assertEq(storedAsset, asset);
        assertEq(startFee, 10_000);
        assertEq(endFee, 1_000);
        assertEq(lastFee, 10_000);
        assertEq(startBlock, uint64(block.number));
        assertEq(durationBlocks, 100);
        assertTrue(enabled);
    }

    function test_onInitialization_DisablesFlatSchedule() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(5_000, 5_000, 0)));

        (,,,,,, bool enabled) = dopplerHook.getFeeScheduleOf(poolId);
        assertFalse(enabled);
    }

    function test_onInitialization_DisablesFlatScheduleWithNonZeroDuration() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(5_000, 5_000, 100)));

        (,,,,, uint64 durationBlocks, bool enabled) = dopplerHook.getFeeScheduleOf(poolId);
        assertEq(durationBlocks, 100);
        assertFalse(enabled);
    }

    /* ---------------------------------------------------------------------- */
    /*                                onSwap()                                */
    /* ---------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    function test_onSwap_IgnoresWhenScheduleDisabled() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(5_000, 5_000, 0)));

        vm.roll(block.number + 20);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        assertEq(updater.updateCount(), 0);
        (,,,,,, bool enabled) = dopplerHook.getFeeScheduleOf(poolId);
        assertFalse(enabled);
    }

    function test_onSwap_UpdatesLinearly() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 100)));

        vm.roll(block.number + 25);

        vm.expectEmit();
        emit FeeUpdated(poolId, 7_750);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        assertEq(updater.lastAsset(), asset);
        assertEq(updater.lastFee(), 7_750);
        assertEq(updater.updateCount(), 1);
    }

    function test_onSwap_FeeIsMonotoneNonIncreasing() public {
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 100)));

        vm.roll(block.number + 10);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
        uint24 fee1 = updater.lastFee();

        vm.roll(block.number + 30);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
        uint24 fee2 = updater.lastFee();

        vm.roll(block.number + 40);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
        uint24 fee3 = updater.lastFee();

        assertLe(fee2, fee1);
        assertLe(fee3, fee2);
    }

    function test_onSwap_ReachesTerminalFeeAndDisables() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 10)));

        vm.roll(block.number + 10);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        assertEq(updater.lastFee(), 1_000);
        assertEq(updater.updateCount(), 1);

        (,,,,,, bool enabledAfterEnd) = dopplerHook.getFeeScheduleOf(poolId);
        assertFalse(enabledAfterEnd);

        vm.roll(block.number + 10);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        assertEq(updater.updateCount(), 1, "should not update after schedule has completed");
    }

    function test_onSwap_ReachesTerminalFeeAtDurationOne() public {
        PoolId poolId = poolKey.toId();
        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(10_000, 1_000, 1)));

        vm.roll(block.number + 1);
        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        assertEq(updater.lastFee(), 1_000);
        (,,,,,, bool enabledAfterEnd) = dopplerHook.getFeeScheduleOf(poolId);
        assertFalse(enabledAfterEnd);
    }

    function testFuzz_onSwap_LastFeeMonotoneAndBounded(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationBlocks,
        uint8 rawSteps
    ) public {
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationBlocks = uint64(bound(rawDurationBlocks, 1, 200));
        uint256 steps = bound(uint256(rawSteps), 1, 64);

        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(startFee, endFee, durationBlocks)));

        PoolId poolId = poolKey.toId();
        uint24 previousLastFee = startFee;

        for (uint256 i; i < steps; ++i) {
            vm.roll(block.number + 1);
            vm.prank(address(updater));
            dopplerHook.onSwap(
                address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
            );

            (,,, uint24 lastFee, uint64 startBlock, uint64 scheduleDuration, bool enabled) =
                dopplerHook.getFeeScheduleOf(poolId);

            assertLe(lastFee, previousLastFee, "last fee must be monotone non-increasing");
            assertGe(lastFee, endFee, "last fee must never go below terminal fee");

            if (block.number >= uint256(startBlock) + uint256(scheduleDuration)) {
                assertFalse(enabled, "schedule should be disabled once terminal fee is reached");
            }

            previousLastFee = lastFee;
        }
    }

    function testFuzz_onSwap_MatchesLinearFormulaAtElapsed(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationBlocks,
        uint16 rawElapsed
    ) public {
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationBlocks = uint64(bound(rawDurationBlocks, 1, 10_000));
        uint256 elapsed = bound(uint256(rawElapsed), 0, uint256(durationBlocks) + 128);

        vm.prank(address(updater));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(startFee, endFee, durationBlocks)));

        PoolId poolId = poolKey.toId();
        vm.roll(block.number + elapsed);

        vm.prank(address(updater));
        dopplerHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        uint24 expectedFee = elapsed >= durationBlocks
            ? endFee
            : uint24(uint256(startFee) - (uint256(startFee - endFee) * elapsed) / durationBlocks);

        (,,, uint24 lastFee,,, bool enabled) = dopplerHook.getFeeScheduleOf(poolId);
        assertEq(lastFee, expectedFee, "unexpected last fee for elapsed blocks");

        uint256 expectedUpdates = expectedFee < startFee ? 1 : 0;
        assertEq(updater.updateCount(), expectedUpdates, "unexpected update count");

        if (expectedUpdates == 1) {
            assertEq(updater.lastAsset(), asset, "asset mismatch on update");
            assertEq(updater.lastFee(), expectedFee, "fee mismatch on update");
        }

        if (elapsed >= durationBlocks) {
            assertFalse(enabled, "schedule should be disabled at or after terminal block");
        } else {
            assertTrue(enabled, "schedule should remain enabled before terminal block");
        }
    }
}
