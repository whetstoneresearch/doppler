// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Airlock } from "src/Airlock.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";

contract TopUpDistributorTest is Test {
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    TopUpDistributor public distributor;

    function setUp() public {
        airlock = new Airlock(airlockOwner);
        distributor = new TopUpDistributor(address(airlock));
    }

    /* ----------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* ----------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(distributor.AIRLOCK()), address(airlock));
    }

    /* ----------------------------------------------------------------------- */
    /*                                setPullUp()                                */
    /* ----------------------------------------------------------------------- */
}
