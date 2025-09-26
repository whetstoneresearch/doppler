// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Airlock } from "src/Airlock.sol";

abstract contract AirlockBaseTest is Test {
    address internal owner = makeAddr("AirlockOwner");
    Airlock internal airlock;

    function setUp() public virtual {
        airlock = new Airlock(owner);
    }
}
