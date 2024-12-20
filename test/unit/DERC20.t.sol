/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { DERC20 } from "src/DERC20.sol";

contract DERC20Test is Test {
    DERC20 public token;

    uint256 public constant INITIAL_SUPPLY = 1e26;

    function test_constructor() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xa);
        recipients[1] = address(0xb);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e20;
        amounts[1] = 2e22;

        token = new DERC20("Test", "TST", INITIAL_SUPPLY, address(0xb0b), address(0xbeef), 0, 0, recipients, amounts);

        assertEq(token.name(), "Test", "Wrong name");
        assertEq(token.symbol(), "TST", "Wrong symbol");
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Wrong total supply");
        assertEq(token.balanceOf(address(0xb0b)), INITIAL_SUPPLY - 1e20 - 2e22, "Wrong balance of recipient");
        assertEq(token.mintStartDate(), block.timestamp + 365 days, "Wrong mint start date");
        assertEq(token.owner(), address(0xbeef), "Wrong owner");
    }
}
