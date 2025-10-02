// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { AirlockBaseTest } from "test/shared/AirlockBaseTest.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { CloneERC20VotesFactory } from "src/CloneERC20VotesFactory.sol";
import { CloneERC20Factory } from "src/CloneERC20Factory.sol";

contract TokenFactoryGasTest is AirlockBaseTest {
    function test_gas_TokenFactory_NoRecipients() public {
        TokenFactory factory = new TokenFactory(address(this));

        vm.startSnapshotGas("TokenFactory", "TokenFactory/NoRecipients");
        factory.create(
            1e30,
            address(this),
            address(this),
            bytes32(0),
            abi.encode("", "", 0, 0, new address[](0), new uint256[](0), "")
        );
        vm.stopSnapshotGas("TokenFactory", "TokenFactory/NoRecipients");
    }

    function test_gas_CloneERC20Factory_NoRecipients() public {
        CloneERC20Factory factory = new CloneERC20Factory(address(this));

        vm.startSnapshotGas("TokenFactory", "CloneERC20Factory/NoRecipients");
        factory.create(
            1e30,
            address(this),
            address(this),
            bytes32(0),
            abi.encode("", "", 0, 0, new address[](0), new uint256[](0), "")
        );
        vm.stopSnapshotGas("TokenFactory", "CloneERC20Factory/NoRecipients");
    }

    function test_gas_CloneERC20VotesFactory_NoRecipients() public {
        CloneERC20VotesFactory factory = new CloneERC20VotesFactory(address(this));

        vm.startSnapshotGas("TokenFactory", "CloneERC20VotesFactory/NoRecipients");
        factory.create(
            1e30,
            address(this),
            address(this),
            bytes32(0),
            abi.encode("", "", 0, 0, new address[](0), new uint256[](0), "")
        );
        vm.stopSnapshotGas("TokenFactory", "CloneERC20VotesFactory/NoRecipients");
    }
}
