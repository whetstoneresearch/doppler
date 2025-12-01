// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract UnlockCallbackTest is BaseTest {
    function test_unlockCallback_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_unlockCallback_SucceedWhenSenderIsPoolManager() public {
        vm.skip(true);
        Doppler.CallbackData memory callbackData =
            Doppler.CallbackData({ key: key, tick: hook.startingTick(), sender: address(0xbeef), isMigration: false });
        vm.prank(address(manager));
        hook.unlock(abi.encode(callbackData));
    }
}
