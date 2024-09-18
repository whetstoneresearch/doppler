/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {BaseTest} from "test/BaseTest.sol";

contract testUnlockCallbackTest is BaseTest {
    function test_unlockCallback_RevertsWhenNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        ghost().hook.unlockCallback("");
    }
}
