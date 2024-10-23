// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";
import {BaseTest} from "test/shared/BaseTest.sol";
import {DopplerHandler} from "test/invariant/DopplerHandler.sol";
import {State} from "src/Doppler.sol";

contract DopplerInvariantsTest is BaseTest {
    DopplerHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new DopplerHandler(key, hook, router, isToken0, usingEth);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactAmountIn.selector;
        selectors[1] = handler.buyExactAmountOut.selector;
        selectors[2] = handler.sellExactIn.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        vm.warp(DEFAULT_STARTING_TIME);
    }

    function afterInvariant() public view {
        console.log("Calls: ", handler.totalCalls());
        console.log("buyExactAmountIn: ", handler.calls(handler.buyExactAmountIn.selector));
        console.log("buyExactAmountOut: ", handler.calls(handler.buyExactAmountOut.selector));
        console.log("sellExactIn: ", handler.calls(handler.sellExactIn.selector));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalTokensSold() public view {
        (,, uint256 totalTokensSold,,,) = hook.state();

        assertEq(totalTokensSold, handler.totalTokensSold());
    }
}
