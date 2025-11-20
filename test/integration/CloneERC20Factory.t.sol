// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { CloneERC20Factory } from "src/modules/token/CloneERC20Factory.sol";

function deployCloneERC20Factory(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (CloneERC20Factory tokenFactory) {
    tokenFactory = new CloneERC20Factory(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(tokenFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.TokenFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return tokenFactory;
}

function prepareCloneERC20FactoryData() pure returns (bytes memory) {
    return abi.encode("name", "symbol", 0, 0, new address[](0), new uint256[](0), "");
}
