/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DERC20 } from "src/DERC20.sol";

contract DERC20Test is Test {
    DERC20 public token;

    function setUp() public { }

    function test_constructor() public {
        token = new DERC20("Test Token", "TST", 1e25, address(0xa), address(0xb), address(0xc), 1e21);

        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TST");
        assertEq(token.balanceOf(address(0xa)), 1e25);
        assertEq(token.owner(), address(0xb));
        assertEq(token.pool(), address(0xc));
        assertEq(token.yearlyMintCap(), 1e21);
    }
}
