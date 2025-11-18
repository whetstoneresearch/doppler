// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ScheduledLaunchDook, SaleHasNotStartedYet } from "src/dooks/ScheduledLaunchDook.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";

contract ScheduledLaunchDookTest is Test {
    address initializer = makeAddr("initializer");

    ScheduledLaunchDook public dook;

    function setUp() public {
        dook = new ScheduledLaunchDook(initializer);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dook.INITIALIZER(), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization(PoolKey calldata poolKey, uint256 startingTime) public {
        vm.prank(initializer);
        dook.onInitialization(address(0), poolKey, abi.encode(startingTime));
        assertEq(dook.getStartingTimeOf(poolKey.toId()), startingTime);
    }

    /* ---------------------------------------------------------------------- */
    /*                                onSwap()                                */
    /* ---------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSaleNotStarted(
        PoolKey calldata poolKey,
        uint256 timestamp,
        uint256 startingTime,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.assume(startingTime > timestamp);
        vm.warp(timestamp);

        vm.prank(initializer);
        dook.onInitialization(address(0), poolKey, abi.encode(startingTime));

        vm.expectRevert(abi.encodeWithSelector(SaleHasNotStartedYet.selector, startingTime, block.timestamp));
        vm.prank(initializer);
        dook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }
}
