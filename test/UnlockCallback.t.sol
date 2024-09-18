/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {BaseTest} from "test/BaseTest.sol";
import {Doppler} from "src/Doppler.sol";

contract testUnlockCallbackTest is BaseTest {
    function test_unlockCallback_RevertsWhenNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        ghost().hook.unlockCallback("");
    }

    function test_unlockCallback_SucceedWhenSenderIsPoolManager() public {
        Doppler.Position[] memory prevPositions;
        Doppler.Position[] memory newPositions;

        Doppler.CallbackData memory callbackData = Doppler.CallbackData({
            prevPositions: prevPositions,
            newPositions: newPositions,
            currentPrice: 0,
            swapPrice: 0,
            key: ghost().key()
        });

        vm.prank(address(manager));
        ghost().hook.unlock(abi.encode(callbackData));
    }
}
