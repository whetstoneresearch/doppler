// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { SwapRestrictorDook } from "src/dooks/SwapRestrictorDook.sol";

contract SwapRestrictorDookTest is Test {
    address initializer = makeAddr("initializer");
    address hook = makeAddr("hook");

    SwapRestrictorDook public dook;

    function test_constructor_big() public {
        address[] memory approved = new address[](100);

        for (uint256 i; i < approved.length; i++) {
            approved[i] = address(uint160(i + 1));
        }

        vm.startSnapshotGas("SwapRestrictorDook", "constructor");
        dook = new SwapRestrictorDook(initializer, hook, approved);
        vm.stopSnapshotGas("SwapRestrictorDook", "constructor");
    }
}
