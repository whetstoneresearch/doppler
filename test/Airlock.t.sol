/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Airlock} from "src/Airlock.sol";

contract AirlockTest is Deployers {
    Airlock airlock;

    function setUp() public {
        deployFreshManager();
        airlock = new Airlock(manager);
    }
}
