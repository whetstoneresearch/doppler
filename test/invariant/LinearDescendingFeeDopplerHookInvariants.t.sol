// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";

import {
    FeeScheduleParams,
    LinearDescendingFeeDopplerHook,
    MAX_LP_FEE
} from "src/dopplerHooks/LinearDescendingFeeDopplerHook.sol";

contract LinearFeeInvariantUpdaterMock {
    address public lastAsset;
    uint24 public lastFee;
    uint256 public updateCount;

    function updateDynamicLPFee(address asset, uint24 lpFee) external {
        lastAsset = asset;
        lastFee = lpFee;
        updateCount++;
    }
}

contract LinearDescendingFeeDopplerHookHandler is Test {
    LinearDescendingFeeDopplerHook public hook;
    LinearFeeInvariantUpdaterMock public updater;

    address public asset = makeAddr("asset");
    address public numeraire = makeAddr("numeraire");
    PoolKey public poolKey;
    PoolId public poolId;

    bool public initialized;
    bool public monotonicityViolated;
    uint24 public previousLastFee;

    constructor() {
        updater = new LinearFeeInvariantUpdaterMock();
        hook = new LinearDescendingFeeDopplerHook(address(updater));
        poolKey = PoolKey({
            currency0: Currency.wrap(asset),
            currency1: Currency.wrap(numeraire),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
    }

    function initialize(uint24 rawStartFee, uint24 rawEndFee, uint64 rawDurationBlocks) external {
        if (initialized) return;

        uint24 startFee = uint24(bound(rawStartFee, 1, MAX_LP_FEE));
        uint24 endFee = uint24(bound(rawEndFee, 0, startFee));

        bool isDescending = startFee > endFee;
        uint64 durationBlocks = isDescending ? uint64(bound(rawDurationBlocks, 1, 200)) : uint64(bound(rawDurationBlocks, 0, 200));

        vm.prank(address(updater));
        hook.onInitialization(asset, poolKey, abi.encode(FeeScheduleParams(startFee, endFee, durationBlocks)));

        previousLastFee = startFee;
        initialized = true;
    }

    function step(uint8 rawJump) external {
        if (!initialized) return;

        uint256 jump = bound(uint256(rawJump), 0, 5);
        vm.roll(block.number + jump);

        vm.prank(address(updater));
        hook.onSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );

        (,,, uint24 lastFee,,,) = hook.getFeeScheduleOf(poolId);
        if (lastFee > previousLastFee) {
            monotonicityViolated = true;
        }
        previousLastFee = lastFee;
    }

    function schedule()
        external
        view
        returns (
            address scheduleAsset,
            uint24 startFee,
            uint24 endFee,
            uint24 lastFee,
            uint64 startBlock,
            uint64 durationBlocks,
            bool enabled
        )
    {
        return hook.getFeeScheduleOf(poolId);
    }
}

contract LinearDescendingFeeDopplerHookInvariants is Test {
    LinearDescendingFeeDopplerHookHandler public handler;

    function setUp() public {
        handler = new LinearDescendingFeeDopplerHookHandler();
        handler.initialize(20_000, 5_000, 64);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.step.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_LastFeeIsMonotoneNonIncreasing() public view {
        assertFalse(handler.monotonicityViolated(), "fee schedule monotonicity violated");
    }

    function invariant_LastFeeIsAlwaysBoundedBySchedule() public view {
        (, uint24 startFee, uint24 endFee, uint24 lastFee,,, ) = handler.schedule();
        assertLe(lastFee, startFee, "last fee exceeds start fee");
        assertGe(lastFee, endFee, "last fee is below end fee");
    }

    function invariant_DisabledScheduleHasTerminalFee() public view {
        (, uint24 startFee, uint24 endFee, uint24 lastFee,,, bool enabled) = handler.schedule();
        if (!enabled && startFee > endFee) {
            assertEq(lastFee, endFee, "disabled descending schedule must be at terminal fee");
        }
    }

    function invariant_UpdateCountBoundedByElapsedAndDuration() public view {
        (,,,, uint64 startBlock, uint64 durationBlocks,) = handler.schedule();
        uint256 elapsed = block.number > startBlock ? block.number - startBlock : 0;
        uint256 maxUpdates = elapsed < durationBlocks ? elapsed : durationBlocks;
        assertLe(handler.updater().updateCount(), maxUpdates, "too many fee updates for elapsed duration");
    }

    function invariant_UpdaterStateMatchesScheduleWhenUpdated() public view {
        (, , , uint24 lastFee,,,) = handler.schedule();
        if (handler.updater().updateCount() > 0) {
            assertEq(handler.updater().lastAsset(), handler.asset(), "updater asset mismatch");
            assertEq(handler.updater().lastFee(), lastFee, "updater fee mismatch");
        }
    }
}
