// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { CloneERC20VotesFactory } from "src/tokens/CloneERC20VotesFactory.sol";

function deployCloneERC20VotesFactory(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (CloneERC20VotesFactory tokenFactory) {
    tokenFactory = new CloneERC20VotesFactory(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(tokenFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.TokenFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return tokenFactory;
}

function prepareCloneERC20VotesFactoryData() pure returns (bytes memory) {
    return abi.encode("name", "symbol", 0, 0, new address[](0), new uint256[](0), "");
}
