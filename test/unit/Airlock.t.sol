/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest} from "test/shared/BaseTest.sol";
import {Airlock} from "src/Airlock.sol";

contract AirlockTest is BaseTest {
    Airlock public airlock;

    function setUp() public override {
        this.setUp();
        airlock = new Airlock(manager);
    }
}
