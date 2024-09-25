/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {BaseTest} from "../shared/BaseTest.sol";
import {Doppler} from "src/Doppler.sol";

contract UnlockCallbackTest is BaseTest {
    function test_unlockCallback_RevertsWhenNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_unlockCallback_SucceedWhenSenderIsPoolManager() public {
        vm.skip(true);
        Doppler.CallbackData memory callbackData =
            Doppler.CallbackData({key: key, tick: hook.getStartingTick(), sender: address(0xbeef)});
        vm.prank(address(manager));
        hook.unlock(abi.encode(callbackData));
    }
}
