// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { Vm } from "forge-std/Vm.sol";

import { Airlock, ModuleState } from "src/Airlock.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInternalInitializer, InitData } from "src/initializers/DopplerHookInternalInitializer.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import {
    BaseIntegrationTest,
    deployNoOpGovernanceFactory,
    deployNoOpMigrator
} from "test/integration/BaseIntegrationTest.sol";
import { deployCloneERC20Factory, prepareCloneERC20FactoryData } from "test/integration/CloneERC20Factory.t.sol";

function deployDopplerHookInternalInitializer(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (DopplerHookInternalInitializer initializer) {
    initializer = DopplerHookInternalInitializer(
        payable(address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            ))
    );

    deployCodeTo("DopplerHookInternalInitializer", abi.encode(address(airlock), address(poolManager)), address(initializer));

    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

function prepareDopplerHookInternalInitializerData(
    address asset,
    address numeraire
) pure returns (bytes memory poolInitializerData) {
    Curve[] memory curves = new Curve[](10);
    int24 tickSpacing = 8;

    for (uint256 i; i < 10; ++i) {
        curves[i].tickLower = int24(uint24(0 + i * 16_000));
        curves[i].tickUpper = 240_000;
        curves[i].numPositions = 10;
        curves[i].shares = WAD / 10;
    }

    Currency currency0 = Currency.wrap(address(numeraire));
    Currency currency1 = Currency.wrap(address(asset));

    (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);
    poolInitializerData = abi.encode(
        InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: new BeneficiaryData[](0),
            dopplerHook: address(0),
            onInitializationDopplerHookCalldata: new bytes(0),
            graduationDopplerHookCalldata: new bytes(0),
            farTick: 200_000
        })
    );
}

contract CloneERC20FactoryDopplerHookInternalInitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "CloneERC20FactoryDopplerHookInternalInitializerNoOpGovernanceFactoryNoOpMigrator";

        CloneERC20Factory tokenFactory = deployCloneERC20Factory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = prepareCloneERC20FactoryData();

        DopplerHookInternalInitializer initializer =
            deployDopplerHookInternalInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        createParams.poolInitializerData = prepareDopplerHookInternalInitializerData(address(0), address(0));
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}
