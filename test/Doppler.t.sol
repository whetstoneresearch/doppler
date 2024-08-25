pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Doppler} from "../src/Doppler.sol";

contract DopplerTest is Test {
    Doppler doppler;

    function setUp() public {
        doppler = new Doppler();
    }

    
}