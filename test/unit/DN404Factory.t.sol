// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { DN404Factory, InvalidDN404InitialSupply, InvalidDN404Unit } from "src/tokens/DN404Factory.sol";
import { DopplerDN404 } from "src/tokens/DopplerDN404.sol";

contract DN404FactoryTest is Test {
    DN404Factory public factory;

    function setUp() public {
        factory = new DN404Factory(address(this));
    }

    function test_constructor() public view {
        assertEq(address(factory.airlock()), address(this));
    }

    function test_create() public {
        uint256 initialSupply = 100_000e18;
        address recipient = address(0xa71c3);
        address owner = address(0xb0b);
        bytes32 salt = hex"beef";
        string memory name = "Test Token";
        string memory symbol = "TT";
        string memory baseURI = "https://example.com/token/";
        uint256 unit = 1000e18;

        vm.recordLogs();
        address tokenAddress =
            factory.create(initialSupply, recipient, owner, salt, abi.encode(name, symbol, baseURI, unit));

        DopplerDN404 token = DopplerDN404(payable(tokenAddress));
        address collection = token.mirrorERC721();

        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.baseURI(), baseURI);
        assertEq(token.unit(), unit);
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.balanceOf(recipient), initialSupply);
        assertEq(token.owner(), owner);
        assertEq(token.mirrorERC721(), collection);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("DN404Created(address,address,address,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != eventSig) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), tokenAddress);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), collection);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), owner);
            assertEq(abi.decode(logs[i].data, (uint256)), initialSupply);
        }
        assertTrue(found);
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
        factory.create(initialSupply, recipient, owner, salt, abi.encode(name, symbol, baseURI, unit));
    }

    function test_create_RevertsWhenUnitIsZero() public {
        vm.expectRevert(InvalidDN404Unit.selector);
        factory.create(
            100_000e18,
            address(0xa71c3),
            address(0xb0b),
            hex"beef",
            abi.encode("Test Token", "TT", "https://example.com/token/", uint256(0))
        );
    }

    function test_create_RevertsWhenInitialSupplyIsNotMultipleOfUnit() public {
        vm.expectRevert(InvalidDN404InitialSupply.selector);
        factory.create(
            100_000e18 + 1,
            address(0xa71c3),
            address(0xb0b),
            hex"beef",
            abi.encode("Test Token", "TT", "https://example.com/token/", uint256(1000e18))
        );
    }
}
