// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { LibClone } from "solady/utils/LibClone.sol";
import { DopplerERC20V1, VestingSchedule } from "src/tokens/DopplerERC20V1.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";

function dopplerERC20V1FactoryData(
    string memory name,
    string memory symbol,
    string memory tokenURI,
    uint256 maxBalanceLimit,
    uint48 balanceLimitEnd,
    address controller,
    address[] memory excludedFromBalanceLimit
) pure returns (bytes memory) {
    return abi.encode(
        name,
        symbol,
        new VestingSchedule[](0),
        new address[](0),
        new uint256[](0),
        new uint256[](0),
        tokenURI,
        maxBalanceLimit,
        balanceLimitEnd,
        controller,
        excludedFromBalanceLimit
    );
}

function defaultDopplerERC20V1FactoryData() pure returns (bytes memory) {
    return dopplerERC20V1FactoryData("Test Token", "TEST", "TOKEN_URI", 0, 0, address(0), new address[](0));
}

function predictDopplerERC20V1Address(DopplerERC20V1Factory factory, bytes32 salt) view returns (address) {
    return LibClone.predictDeterministicAddress(factory.IMPLEMENTATION(), salt, address(factory));
}

function createDopplerERC20V1(
    DopplerERC20V1Factory factory,
    uint256 initialSupply,
    address recipient,
    address owner,
    bytes32 salt
) returns (DopplerERC20V1) {
    return DopplerERC20V1(factory.create(initialSupply, recipient, owner, salt, defaultDopplerERC20V1FactoryData()));
}
