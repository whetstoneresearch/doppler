// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { DN404Factory } from "src/DN404Factory.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";

contract DN404FactoryTest is Test {
    DN404Factory public factory;

    function setUp() public {
        factory = new DN404Factory(address(this));
    }

    function test_constructor() public view {
        assertEq(address(factory.airlock()), address(this));
    }

    function test_create() public {
        uint256 initialSupply = 1e20;
        address recipient = address(0xa71c3);
        address owner = address(0xb0b);
        bytes32 salt = hex"beef";
        string memory name = "Test Token";
        string memory symbol = "TT";
        string memory baseURI = "https://example.com/token/";
        uint256 unit = 1000e18;

        factory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            abi.encode(name, symbol, baseURI, unit)
        );
    }

    function test_create_RevertsWhenSenderNotAirlock() public {
        uint256 initialSupply = 1e20;
        address recipient = address(0xa71c3);
        address owner = address(0xb0b);
        bytes32 salt = hex"beef";
        string memory name = "Test Token";
        string memory symbol = "TT";
        string memory baseURI = "https://example.com/token/";
        uint256 unit = 1000e18;

        vm.startPrank(address(0xdead));
        vm.expectRevert(SenderNotAirlock.selector);
        factory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            abi.encode(name, symbol, baseURI, unit)
        );
    }
}
