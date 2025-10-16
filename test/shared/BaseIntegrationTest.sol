// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";

import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { WETH } from "@solady/tokens/WETH.sol";
import {
    UniswapV2Migrator,
    ILiquidityMigrator,
    IUniswapV2Router02,
    IUniswapV2Factory
} from "src/UniswapV2Migrator.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";

abstract contract BaseIntegrationTest is Deployers, DeployPermit2 {
    address internal AIRLOCK_OWNER = makeAddr("AIRLOCK_OWNER");

    IAllowanceTransfer public permit2;
    Airlock public airlock;
    IPositionManager public positionManager;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );
        airlock = new Airlock(AIRLOCK_OWNER);
    }

    // Solidity doesn't like it when you pass an overloaded function as an argument so we wrap it
    function _deployCodeTo(
        string memory what,
        bytes memory args,
        address where
    ) internal {
        deployCodeTo(what, args, where);
    }
}

// TODO: Move these functions into dedicated integration test files

function deployNoOpMigrator(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (NoOpMigrator migrator) {
    migrator = new NoOpMigrator(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(migrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return migrator;
}

function deployNoOpGovernanceFactory(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (NoOpGovernanceFactory governanceFactory) {
    governanceFactory = new NoOpGovernanceFactory();
    address[] memory modules = new address[](1);
    modules[0] = address(governanceFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.GovernanceFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return governanceFactory;
}

function deployTokenFactory(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (TokenFactory tokenFactory) {
    tokenFactory = new TokenFactory(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(tokenFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.TokenFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return tokenFactory;
}

function prepareTokenFactoryData() returns (bytes memory) { }

function deployGovernanceFactory(
    Vm vm,
    Airlock airlock,
    address airlockOwner
) returns (GovernanceFactory governanceFactory) {
    governanceFactory = new GovernanceFactory(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(governanceFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.GovernanceFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return governanceFactory;
}

function deployUniswapV2Migrator(
    Vm vm,
    Airlock airlock,
    address airlockOwner,
    address uniswapV2Factory,
    address uniswapV2Router
) returns (UniswapV2Migrator migrator) {
    migrator = new UniswapV2Migrator(
        address(airlock), IUniswapV2Factory(uniswapV2Factory), IUniswapV2Router02(uniswapV2Router), airlockOwner
    );
    address[] memory modules = new address[](1);
    modules[0] = address(migrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

// Utility functions

function deployWeth() returns (address weth) {
    return address(new WETH());
}

function _deployCode(
    bytes memory creationCode
) returns (address deployedTo) {
    assembly {
        deployedTo := create(0, add(creationCode, 0x20), mload(creationCode))
    }
    require(deployedTo != address(0), "Deploy failed");
}

function deployUniswapV2(
    Vm vm,
    address weth
) returns (address factory, address router) {
    factory = _deployCode(
        abi.encodePacked(vm.parseBytes(vm.readFile("./script/utils/uniswapV2Factory.bytecode")), abi.encode(address(0)))
    );

    router = _deployCode(
        abi.encodePacked(
            vm.parseBytes(vm.readFile("./script/utils/uniswapV2Router02.bytecode")), abi.encode(factory, weth)
        )
    );
}

