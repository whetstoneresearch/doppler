// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import { SaleHasNotStartedYet, ScheduledLaunchDopplerHook } from "src/dopplerHooks/ScheduledLaunchDopplerHook.sol";

contract ScheduledLaunchDopplerHookTest is Test {
    address initializer = makeAddr("initializer");

    ScheduledLaunchDopplerHook public dopplerHook;

    function setUp() public {
        dopplerHook = new ScheduledLaunchDopplerHook(initializer);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dopplerHook.INITIALIZER(), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization(PoolKey calldata poolKey, uint256 startingTime) public {
        vm.prank(initializer);
        dopplerHook.onInitialization(address(0), poolKey, abi.encode(startingTime));
        assertEq(dopplerHook.getStartingTimeOf(poolKey.toId()), startingTime);
    }

    function test_onInitialization_RevertsWhenSenderNotInitializer(
        PoolKey calldata poolKey,
        uint256 startingTime
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(address(0), poolKey, abi.encode(startingTime));
    }

    /* ---------------------------------------------------------------------- */
    /*                                onSwap()                                */
    /* ---------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSenderNotInitializer(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onSwap_RevertsWhenSaleNotStarted(
        PoolKey calldata poolKey,
        uint256 timestamp,
        uint256 startingTime,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.assume(startingTime > timestamp);
        vm.warp(timestamp);

        vm.prank(initializer);
        dopplerHook.onInitialization(address(0), poolKey, abi.encode(startingTime));

        vm.expectRevert(abi.encodeWithSelector(SaleHasNotStartedYet.selector, startingTime, block.timestamp));
        vm.prank(initializer);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onSwap_PassesAfterStartingTime(
        PoolKey calldata poolKey,
        uint256 timestamp,
        uint256 startingTime,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.assume(startingTime <= timestamp);
        vm.warp(timestamp);

        vm.prank(initializer);
        dopplerHook.onInitialization(address(0), poolKey, abi.encode(startingTime));

        vm.prank(initializer);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }
}
