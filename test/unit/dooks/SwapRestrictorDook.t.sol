// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { SwapRestrictorDook } from "src/dooks/SwapRestrictorDook.sol";

contract SwapRestrictorDookTest is Test {
    address initializer = makeAddr("initializer");

    SwapRestrictorDook public dook;

    function setUp() public {
        dook = new SwapRestrictorDook(initializer);
    }
}
