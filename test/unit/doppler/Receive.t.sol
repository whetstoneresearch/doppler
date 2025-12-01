// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { SenderNotPoolManager } from "src/initializers/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract ReceiveTest is BaseTest {
    function test_receive_RevertsIfSenderNotPoolManager() public {
        vm.expectRevert(SenderNotPoolManager.selector);
        payable(address(hook)).transfer(1 ether);
    }

    function test_receive_ReceivesIfSenderIsPoolManager() public {
        deal(address(manager), 1 ether);
        vm.prank(address(manager));
        payable(address(hook)).transfer(1 ether);
    }
}
