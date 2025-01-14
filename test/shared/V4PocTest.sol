pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract V4PocTest is BaseTest {
    function test_v4_poc() public {
        // TODO: YOUR DOPPLER V4 POC HERE
        console.log("hook starting time", hook.getStartingTime());
    }
}
