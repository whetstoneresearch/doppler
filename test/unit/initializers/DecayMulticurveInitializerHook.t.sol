// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import {
    DecayMulticurveInitializerHook,
    FeeScheduleSet,
    FeeTooHigh,
    FeeUpdated,
    InvalidDurationSeconds,
    InvalidFeeRange,
    MAX_LP_FEE
} from "src/initializers/DecayMulticurveInitializerHook.sol";
import { ModifyLiquidity, OnlyInitializer, Swap } from "src/initializers/UniswapV4MulticurveInitializerHook.sol";

contract MockPoolManagerForDecayHook {
    using PoolIdLibrary for PoolKey;

    PoolId public lastPoolId;
    uint24 public lastFee;
    uint256 public updateCount;

    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        lastPoolId = key.toId();
        lastFee = newDynamicLPFee;
        updateCount++;
    }
}

contract DecayMulticurveInitializerHookTest is Test {
    DecayMulticurveInitializerHook public hook;
    MockPoolManagerForDecayHook public poolManager;
    address public initializer = makeAddr("Initializer");

    PoolKey internal poolKey;
    PoolKey internal emptyPoolKey;
    IPoolManager.ModifyLiquidityParams internal emptyParams;

    function setUp() public {
        poolManager = new MockPoolManagerForDecayHook();

        hook = DecayMulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        deployCodeTo("DecayMulticurveInitializerHook", abi.encode(address(poolManager), initializer), address(hook));

        poolKey = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 8,
            hooks: IHooks(address(hook))
        });
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(address(hook.INITIALIZER()), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                beforeInitialize()                                */
    /* -------------------------------------------------------------------------------- */

    function test_beforeInitialize_RevertsWhenSenderParamNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(0), emptyPoolKey, 0);
    }

    function test_beforeInitialize_RevertsWhenSenderParamNotInitializer() public {
        vm.prank(address(poolManager));
        vm.expectRevert(OnlyInitializer.selector);
        hook.beforeInitialize(address(0), emptyPoolKey, 0);
    }

    function test_beforeInitialize_PassesWhenSenderParamInitializer() public {
        vm.prank(address(poolManager));
        hook.beforeInitialize(initializer, emptyPoolKey, 0);
    }

    /* ---------------------------------------------------------------------------------- */
    /*                                beforeAddLiquidity()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_beforeAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(0), emptyPoolKey, emptyParams, new bytes(0));
    }

    function test_beforeAddLiquidity_PassesWhenMsgSenderIsPoolManager(address sender) public {
        vm.prank(address(poolManager));
        hook.beforeAddLiquidity(sender, emptyPoolKey, emptyParams, new bytes(0));
    }

    /* --------------------------------------------------------------------------------- */
    /*                                afterAddLiquidity()                                */
    /* --------------------------------------------------------------------------------- */

    function test_afterAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterAddLiquidity_PassesWhenMsgSenderPoolManager(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        vm.expectEmit();
        emit ModifyLiquidity(key, params);

        vm.prank(address(poolManager));
        hook.afterAddLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* ------------------------------------------------------------------------------------ */
    /*                                afterRemoveLiquidity()                                */
    /* ------------------------------------------------------------------------------------ */

    function test_afterRemoveLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterRemoveLiquidity_PassesWhenMsgSenderPoolManager(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        vm.expectEmit();
        emit ModifyLiquidity(key, params);

        vm.prank(address(poolManager));
        hook.afterRemoveLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                setSchedule()                               */
    /* -------------------------------------------------------------------------- */

    function test_setSchedule_RevertsWhenSenderNotInitializer() public {
        vm.expectRevert(OnlyInitializer.selector);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 1000, 100);
    }

    function test_setSchedule_RevertsWhenStartFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, MAX_LP_FEE + 1, 1000, 100);
    }

    function test_setSchedule_RevertsWhenEndFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, MAX_LP_FEE + 1));
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, MAX_LP_FEE + 1, 100);
    }

    function test_setSchedule_RevertsWhenFeeRangeAscending() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRange.selector, 1000, 10_000));
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 1000, 10_000, 100);
    }

    function test_setSchedule_RevertsWhenDescendingDurationIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDurationSeconds.selector, 0));
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 1000, 0);
    }

    function test_setSchedule_StoresScheduleAndEmitsEvent() public {
        PoolId poolId = poolKey.toId();
        uint256 startingTime = block.timestamp + 100;

        vm.expectEmit();
        emit FeeScheduleSet(poolId, startingTime, 10_000, 1000, 100);
        vm.prank(initializer);
        hook.setSchedule(poolKey, startingTime, 10_000, 1000, 100);

        (uint48 storedStart, uint24 startFee, uint24 endFee, uint24 lastFee, uint48 durationSeconds, bool isComplete) =
            hook.getFeeScheduleOf(poolId);
        assertEq(storedStart, startingTime);
        assertEq(startFee, 10_000);
        assertEq(endFee, 1000);
        assertEq(lastFee, 10_000);
        assertEq(durationSeconds, 100);
        assertFalse(isComplete);
        assertEq(PoolId.unwrap(poolManager.lastPoolId()), PoolId.unwrap(poolId));
        assertEq(poolManager.lastFee(), 10_000);
        assertEq(poolManager.updateCount(), 1);
    }

    function test_setSchedule_ClampsPastStartAndDisablesFlatSchedule() public {
        PoolId poolId = poolKey.toId();
        vm.warp(1000);

        vm.prank(initializer);
        hook.setSchedule(poolKey, 999, 5000, 5000, 0);

        (uint48 storedStart, uint24 startFee, uint24 endFee, uint24 lastFee, uint48 durationSeconds, bool isComplete) =
            hook.getFeeScheduleOf(poolId);
        assertEq(storedStart, 1000);
        assertEq(startFee, 5000);
        assertEq(endFee, 5000);
        assertEq(lastFee, 5000);
        assertEq(durationSeconds, 0);
        assertTrue(isComplete);
        assertEq(PoolId.unwrap(poolManager.lastPoolId()), PoolId.unwrap(poolId));
        assertEq(poolManager.lastFee(), 5000);
        assertEq(poolManager.updateCount(), 1);

        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 1, "flat schedules should early-exit in beforeSwap");
    }

    /* -------------------------------------------------------------------------- */
    /*                                beforeSwap()                                */
    /* -------------------------------------------------------------------------- */

    function test_beforeSwap_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(
            address(0),
            emptyPoolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
    }

    function test_beforeSwap_UnknownPool_NoOp() public {
        assertEq(poolManager.updateCount(), 0);

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(lpFeeOverride, 0);
        assertEq(poolManager.updateCount(), 0, "unknown pools should not trigger fee updates");
    }

    function test_beforeSwap_AllowsBeforeStartingTimeAtStartFee() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp + 10, 10_000, 1000, 100);

        vm.warp(block.timestamp + 1);
        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(lpFeeOverride, 0);
        assertEq(PoolId.unwrap(poolManager.lastPoolId()), PoolId.unwrap(poolId));
        assertEq(poolManager.lastFee(), 10_000);
        assertEq(poolManager.updateCount(), 1, "no additional update expected before schedule start");

        (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, 10_000, "lastFee remains startFee before decay begins");
        assertFalse(isComplete, "descending schedule should not be complete before start");
    }

    function test_beforeSwap_UpdatesFeeUsingTimestamp() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 100);

        vm.warp(block.timestamp + 25);
        vm.expectEmit();
        emit FeeUpdated(poolId, 8000);
        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(lpFeeOverride, 0);
        assertEq(PoolId.unwrap(poolManager.lastPoolId()), PoolId.unwrap(poolId));
        assertEq(poolManager.lastFee(), 8000);
        assertEq(poolManager.updateCount(), 2);

        (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, 8000);
        assertFalse(isComplete);
    }

    function test_beforeSwap_ReachesTerminalFeeAndDisables() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 10);

        vm.warp(block.timestamp + 10);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );

        assertEq(poolManager.lastFee(), 2000);
        assertEq(poolManager.updateCount(), 2);

        (,,, uint24 lastFee,, bool isCompleteAfterTerminalSwap) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, 2000);
        assertTrue(isCompleteAfterTerminalSwap, "schedule should mark complete at terminal fee");

        vm.warp(block.timestamp + 20);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "must not update after terminal fee reached");

        (,,, uint24 lastFeeAfter,, bool isCompleteAfterEarlyExit) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFeeAfter, 2000);
        assertTrue(isCompleteAfterEarlyExit, "completion flag should remain set");
    }

    function test_beforeSwap_SameTimestampDoubleSwapSingleUpdate() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 100);

        vm.warp(block.timestamp + 25);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "first swap at timestamp should update once");

        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "second swap at same timestamp should not update");

        (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, 8000);
        assertFalse(isComplete);
    }

    function test_beforeSwap_DurationOne_SecondBoundary() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 1);

        // At schedule start boundary: no decay yet.
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 1, "start boundary should not trigger fee update");
        (,,, uint24 feeAtStart,, bool isCompleteAtStart) = hook.getFeeScheduleOf(poolId);
        assertEq(feeAtStart, 10_000);
        assertFalse(isCompleteAtStart);

        // At +1s: schedule reaches terminal fee and completes.
        vm.warp(block.timestamp + 1);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "terminal boundary should apply end fee once");
        (,,, uint24 feeAtTerminal,, bool isCompleteAtTerminal) = hook.getFeeScheduleOf(poolId);
        assertEq(feeAtTerminal, 2000);
        assertTrue(isCompleteAtTerminal);

        // After completion: beforeSwap should early-exit.
        vm.warp(block.timestamp + 1);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "completed schedule should not update again");
    }

    function test_beforeSwap_FlatScheduleNonzeroDuration_ImmediateComplete() public {
        PoolId poolId = poolKey.toId();
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp + 10, 5000, 5000, 777);

        (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolId);
        assertEq(lastFee, 5000);
        assertTrue(isComplete, "flat schedule should complete immediately");
        assertEq(poolManager.updateCount(), 1, "only seed update expected");

        vm.warp(block.timestamp + 1000);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 1, "flat completed schedule should no-op");
    }

    function testFuzz_beforeSwap_MatchesLinearTimeFormula(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint16 rawElapsed
    ) public {
        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationSeconds = uint64(bound(rawDurationSeconds, 1, 10_000));
        uint256 elapsed = bound(uint256(rawElapsed), 0, uint256(durationSeconds) + 128);

        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, startFee, endFee, durationSeconds);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );

        uint24 expectedFee = elapsed >= durationSeconds
            ? endFee
            : uint24(uint256(startFee) - (uint256(startFee - endFee) * elapsed) / durationSeconds);

        (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolKey.toId());
        assertEq(lastFee, expectedFee);

        uint256 expectedUpdates = expectedFee < startFee ? 2 : 1;
        assertEq(poolManager.updateCount(), expectedUpdates);
        assertEq(isComplete, elapsed >= durationSeconds, "completion should only flip once terminal is reached");
    }

    function testFuzz_beforeSwap_VariousScheduleShapes(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset,
        uint32 rawT1,
        uint32 rawT2,
        uint32 rawT3
    ) public {
        vm.warp(1_000_000);

        uint24 startFee = uint24(bound(rawStartFee, 0, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee));
        bool descending = startFee > endFee;

        uint64 durationSeconds = descending ? uint64(bound(rawDurationSeconds, 1, 200_000)) : 0;
        uint256 startOffset = bound(uint256(rawStartOffset), 0, 200_000);
        uint256 requestedStartingTime = block.timestamp + startOffset;

        vm.prank(initializer);
        hook.setSchedule(poolKey, requestedStartingTime, startFee, endFee, durationSeconds);

        (uint48 storedStartTime,,,,,) = hook.getFeeScheduleOf(poolKey.toId());
        uint256 scheduleStartTime = storedStartTime;

        uint256 horizon = startOffset + uint256(durationSeconds) + 5000;
        uint256 dt1 = bound(uint256(rawT1), 0, horizon);
        uint256 dt2 = bound(uint256(rawT2), 0, horizon);
        uint256 dt3 = bound(uint256(rawT3), 0, horizon);

        uint256 t1 = block.timestamp + _min3(dt1, dt2, dt3);
        uint256 t2 = block.timestamp + _mid3(dt1, dt2, dt3);
        uint256 t3 = block.timestamp + _max3(dt1, dt2, dt3);

        uint24 previousLastFee = startFee;

        vm.warp(t1);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        (,,, uint24 lastFee1,,) = hook.getFeeScheduleOf(poolKey.toId());
        uint24 expected1 = _expectedFeeAt(startFee, endFee, durationSeconds, scheduleStartTime, t1);
        assertEq(lastFee1, expected1, "unexpected fee at t1");
        assertLe(lastFee1, previousLastFee, "fee must be monotone");
        assertLe(lastFee1, startFee, "fee above start");
        assertGe(lastFee1, endFee, "fee below end");
        previousLastFee = lastFee1;

        vm.warp(t2);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        (,,, uint24 lastFee2,,) = hook.getFeeScheduleOf(poolKey.toId());
        uint24 expected2 = _expectedFeeAt(startFee, endFee, durationSeconds, scheduleStartTime, t2);
        assertEq(lastFee2, expected2, "unexpected fee at t2");
        assertLe(lastFee2, previousLastFee, "fee must be monotone");
        assertLe(lastFee2, startFee, "fee above start");
        assertGe(lastFee2, endFee, "fee below end");
        previousLastFee = lastFee2;

        vm.warp(t3);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        (,,, uint24 lastFee3,, bool isComplete) = hook.getFeeScheduleOf(poolKey.toId());
        uint24 expected3 = _expectedFeeAt(startFee, endFee, durationSeconds, scheduleStartTime, t3);
        assertEq(lastFee3, expected3, "unexpected fee at t3");
        assertLe(lastFee3, previousLastFee, "fee must be monotone");
        assertLe(lastFee3, startFee, "fee above start");
        assertGe(lastFee3, endFee, "fee below end");
        bool expectedComplete = !descending || (t3 >= scheduleStartTime + durationSeconds);
        assertEq(isComplete, expectedComplete, "unexpected completion state");

        // One seed update at setSchedule + at most one update per swap.
        assertLe(poolManager.updateCount(), 4, "too many updates");
    }

    function testFuzz_beforeSwap_MultiSwapMonotoneAndBounded(
        uint24 rawStartFee,
        uint24 rawEndFee,
        uint64 rawDurationSeconds,
        uint32 rawStartOffset,
        uint16[8] memory rawStepOffsets
    ) public {
        vm.warp(2_000_000);

        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee - 1));
        uint64 durationSeconds = uint64(bound(rawDurationSeconds, 1, 200_000));
        uint256 startOffset = bound(uint256(rawStartOffset), 0, 200_000);
        uint256 requestedStartingTime = block.timestamp + startOffset;

        vm.prank(initializer);
        hook.setSchedule(poolKey, requestedStartingTime, startFee, endFee, durationSeconds);

        (uint48 storedStartTime,,,,,) = hook.getFeeScheduleOf(poolKey.toId());
        uint256 scheduleStartTime = storedStartTime;

        uint256 currentTime = block.timestamp;
        uint24 previousLastFee = startFee;
        bool sawCompletion = false;

        for (uint256 i; i < rawStepOffsets.length; i++) {
            uint256 step = bound(uint256(rawStepOffsets[i]), 0, 40_000);
            currentTime += step;

            vm.warp(currentTime);
            uint256 updatesBefore = poolManager.updateCount();
            vm.prank(address(poolManager));
            hook.beforeSwap(
                address(0),
                poolKey,
                IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
                new bytes(0)
            );
            uint256 updatesAfter = poolManager.updateCount();

            (,,, uint24 lastFee,, bool isComplete) = hook.getFeeScheduleOf(poolKey.toId());
            assertLe(lastFee, previousLastFee, "fee must be monotone non-increasing");
            assertLe(lastFee, startFee, "fee above start");
            assertGe(lastFee, endFee, "fee below end");

            if (sawCompletion) {
                assertEq(updatesAfter, updatesBefore, "must not update after completion");
            }

            if (isComplete) {
                assertEq(lastFee, endFee, "completed schedule must be at terminal fee");
            }

            sawCompletion = sawCompletion || isComplete;
            previousLastFee = lastFee;
        }

        bool expectedComplete = currentTime >= scheduleStartTime + durationSeconds;
        (,,, uint24 finalFee,, bool finalIsComplete) = hook.getFeeScheduleOf(poolKey.toId());
        assertEq(finalIsComplete, expectedComplete, "unexpected completion state at end of sequence");
        if (expectedComplete) {
            assertEq(finalFee, endFee, "completed schedule should end at terminal fee");
        }
    }

    function test_beforeSwap_Gas_ActiveSchedule() public {
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 100);

        vm.warp(block.timestamp + 25);
        vm.startSnapshotGas("DecayHook beforeSwap", "active");
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        vm.stopSnapshotGas("DecayHook beforeSwap", "active");
    }

    function test_beforeSwap_Gas_CompletedSchedule() public {
        vm.prank(initializer);
        hook.setSchedule(poolKey, block.timestamp, 10_000, 2000, 1);

        vm.warp(block.timestamp + 1);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        assertEq(poolManager.updateCount(), 2, "must complete first");

        vm.warp(block.timestamp + 1);
        vm.startSnapshotGas("DecayHook beforeSwap", "completed");
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(0),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
        vm.stopSnapshotGas("DecayHook beforeSwap", "completed");
        assertEq(poolManager.updateCount(), 2, "completed schedule should no-op");
    }

    function _expectedFeeAt(
        uint24 startFee,
        uint24 endFee,
        uint64 durationSeconds,
        uint256 startingTime,
        uint256 timestamp
    ) internal pure returns (uint24) {
        if (startFee <= endFee) return startFee;
        if (timestamp <= startingTime) return startFee;

        uint256 elapsed = timestamp - startingTime;
        if (elapsed >= durationSeconds) return endFee;

        uint256 feeRange = uint256(startFee - endFee);
        uint256 feeDelta = feeRange * elapsed / durationSeconds;
        if (feeDelta > feeRange) feeDelta = feeRange;
        if (feeDelta > uint256(startFee)) feeDelta = uint256(startFee);

        uint24 currentFee = uint24(uint256(startFee) - feeDelta);
        return currentFee < endFee ? endFee : currentFee;
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }

    function _max3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a > b ? (a > c ? a : c) : (b > c ? b : c);
    }

    function _mid3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a + b + c - _min3(a, b, c) - _max3(a, b, c);
    }

    /* ------------------------------------------------------------------------- */
    /*                                afterSwap()                                */
    /* ------------------------------------------------------------------------- */

    function test_afterSwap_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(
            address(0),
            emptyPoolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterSwap_EmitsEventAndReturnsZeroDelta(
        address sender,
        int128 amount0,
        int128 amount1,
        bytes memory hookData
    ) public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: 0 });

        vm.expectEmit();
        emit Swap(sender, poolKey, poolKey.toId(), params, amount0, amount1, hookData);

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            hook.afterSwap(sender, poolKey, params, toBalanceDelta(amount0, amount1), hookData);
        assertEq(selector, hook.afterSwap.selector);
        assertEq(hookDelta, 0);
    }
}
