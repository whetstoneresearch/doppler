// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";

contract TokenFactoryTest is Test {
    TokenFactory public factory;

    function setUp() public {
        factory = new TokenFactory(address(this));
    }

    function test_constructor() public view {
        assertEq(address(factory.airlock()), address(this));
    }

    function test_create() public {
        uint256 initialSupply = 1e30;
        address recipient = address(0xa71c3);
        address owner = address(0xb0b);
        bytes32 salt = hex"beef";
        string memory name = "Test Token";
        string memory symbol = "TT";
        uint256 yearlyMintRate = 1e16;
        uint256 vestingDuration = 365 days;
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        factory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            abi.encode(name, symbol, yearlyMintRate, vestingDuration, recipients, amounts, "")
        );
    }

    function test_create_RevertsWhenSenderNotAirlock() public {
        uint256 initialSupply = 1e30;
        address recipient = address(0xa71c3);
        address owner = address(0xb0b);
        bytes32 salt = hex"beef";
        string memory name = "Test Token";
        string memory symbol = "TT";
        uint256 yearlyMintRate = 1e25;
        uint256 vestingDuration = 365 days;
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.startPrank(address(0xdead));
        vm.expectRevert(SenderNotAirlock.selector);
        factory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            abi.encode(name, symbol, yearlyMintRate, vestingDuration, recipients, amounts)
        );
    }
}
