// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";

import { WETH } from "@solady/tokens/WETH.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import {
    ILiquidityMigrator,
    IUniswapV2Factory,
    UniswapV2MigratorSplit
} from "src/migrators/UniswapV2MigratorSplit.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { dopplerERC20V1FactoryData, predictDopplerERC20V1Address } from "test/shared/DopplerERC20V1FactoryHelper.sol";

/**
 * @dev Integration tests can inherit from this base contract and override the `setUp` function to update the `CreateParams`,
 * then the `test_create` and `test_migrate` functions will be run automatically to try out the integration of the modules
 * and measure gas usage.
 */
abstract contract BaseIntegrationTest is Deployers {
    address internal AIRLOCK_OWNER = makeAddr("AIRLOCK_OWNER");

    Airlock public airlock;

    /// @dev Name of the integration test, used for gas snapshots
    string internal name;

    /// @dev Parameters used to create the asset in the Airlock, must be filled by the inheriting contract
    CreateParams internal createParams;

    address internal asset;
    address internal pool;
    address internal governance;
    address internal timelock;
    address internal migrationPool;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        airlock = new Airlock(AIRLOCK_OWNER);
    }

    function test_create() public {
        require(bytes(name).length > 0, "Name is not set");
        vm.startSnapshotGas(name, "create");
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        vm.stopSnapshotGas(name, "create");
    }

    function _beforeMigrate() internal virtual {
        vm.skip(true);
    }

    function test_migrate() public {
        require(bytes(name).length > 0, "Name is not set");
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
        _beforeMigrate();
        vm.startSnapshotGas(name, "migrate");
        airlock.migrate(asset);
        vm.stopSnapshotGas(name, "migrate");
    }

    // Solidity doesn't like it when you pass an overloaded function as an argument so we wrap it
    function _deployCodeTo(string memory what, bytes memory args, address where) internal {
        deployCodeTo(what, args, where);
    }
}

// TODO: Move these functions into dedicated integration test files

function deployNoOpMigrator(Vm vm, Airlock airlock, address airlockOwner) returns (NoOpMigrator migrator) {
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

function deployTokenFactory(Vm vm, Airlock airlock, address airlockOwner) returns (DopplerERC20V1Factory tokenFactory) {
    tokenFactory = new DopplerERC20V1Factory(address(airlock));
    address[] memory modules = new address[](1);
    modules[0] = address(tokenFactory);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.TokenFactory;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
    return tokenFactory;
}

function prepareTokenFactoryData(
    Vm vm,
    address airlock,
    address tokenFactory,
    bytes32 salt
) view returns (address asset, bytes memory data) {
    string memory name = "Test Token";
    string memory symbol = "TEST";
    string memory uri = "TOKEN_URI";

    asset = predictDopplerERC20V1Address(DopplerERC20V1Factory(tokenFactory), salt);
    data = dopplerERC20V1FactoryData(name, symbol, uri, 0, 0, address(0), new address[](0));
}

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

function prepareGovernanceFactoryData() pure returns (bytes memory) {
    return abi.encode("Test Token", 7200, 50_400, 0);
}

function deployUniswapV2MigratorSplit(
    Vm vm,
    Airlock airlock,
    address uniswapV2Factory,
    TopUpDistributor topUpDistributor,
    address weth
) returns (UniswapV2MigratorSplit migrator) {
    migrator = new UniswapV2MigratorSplit(address(airlock), IUniswapV2Factory(uniswapV2Factory), topUpDistributor, weth);
    address[] memory modules = new address[](1);
    modules[0] = address(migrator);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.LiquidityMigrator;
    vm.prank(airlock.owner());
    airlock.setModuleState(modules, states);
}

function deployTopUpDistributor(Vm vm, Airlock airlock) returns (TopUpDistributor topUpDistributor) {
    new TopUpDistributor(address(airlock));
}

// Utility functions

function deployWeth() returns (address weth) {
    return address(new WETH());
}

function _deployCode(bytes memory creationCode) returns (address deployedTo) {
    assembly {
        deployedTo := create(0, add(creationCode, 0x20), mload(creationCode))
    }
    require(deployedTo != address(0), "Deploy failed");
}

function deployUniswapV2(Vm vm, address weth) returns (address factory, address router) {
    factory = _deployCode(
        abi.encodePacked(vm.parseBytes(vm.readFile("./script/utils/uniswapV2Factory.bytecode")), abi.encode(address(0)))
    );

    router = _deployCode(
        abi.encodePacked(
            vm.parseBytes(vm.readFile("./script/utils/uniswapV2Router02.bytecode")), abi.encode(factory, weth)
        )
    );
}
