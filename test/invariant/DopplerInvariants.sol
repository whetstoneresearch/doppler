// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest} from "test/shared/BaseTest.sol";

contract DopplerInvariantsTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function afterInvariant() public view {}

    function invariant_works() public view {
        assertTrue(true);
    }
}
