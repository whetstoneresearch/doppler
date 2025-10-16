// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { Airlock } from "src/Airlock.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import {
    BaseIntegrationTest,
    deployUniswapV2,
    deployWeth,
    deployUniswapV2Migrator,
    deployGovernanceFactory,
    deployTokenFactory
} from "test/shared/BaseIntegrationTest.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import {
    DEFAULT_MINIMUM_PROCEEDS,
    DEFAULT_MAXIMUM_PROCEEDS,
    DEFAULT_GAMMA,
    DEFAULT_EPOCH_LENGTH
} from "test/shared/DopplerFixtures.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { deployCloneERC20Factory } from "test/integration/CloneERC20Factory.t.sol";
import { CloneERC20Factory } from "src/CloneERC20Factory.sol";

int24 constant DEFAULT_START_TICK = 6000;
int24 constant DEFAULT_END_TICK = 60_000;
uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;

function deployUniswapV4Initializer(
    Vm vm,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (DopplerDeployer deployer, UniswapV4Initializer initializer) {
    deployer = new DopplerDeployer(IPoolManager(poolManager));
    initializer = new UniswapV4Initializer(address(airlock), IPoolManager(poolManager), deployer);
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

contract UniswapV4InitializerIntegrationTest is BaseIntegrationTest {
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;

    function setUp() public override {
        super.setUp();
        (deployer, initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        (address factory, address router) = deployUniswapV2(vm, deployWeth());
        migrator = deployUniswapV2Migrator(vm, airlock, AIRLOCK_OWNER, factory, router);
        (deployer, initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
    }

    function test_TokenFactory_GovernanceFactory_UniswapV4Initializer_UniswapV2Migrator() public {
        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 3 days,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            8,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );

        uint256 initialSupply = 1e23;
        uint256 numTokensToSell = 1e23;

        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (bytes32 salt,,) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        vm.startSnapshotGas("Create", "TokenFactory;GovernanceFactory;UniswapV4Initializer;UniswapV2Migrator");
        airlock.create(createParams);
        vm.stopSnapshotGas("Create", "TokenFactory;GovernanceFactory;UniswapV4Initializer;UniswapV2Migrator");
    }

    function test_CloneERC20Factory_GovernanceFactory_UniswapV4Initializer_UniswapV2Migrator() public {
        CloneERC20Factory tokenFactory = deployCloneERC20Factory(vm, airlock, AIRLOCK_OWNER);

        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 3 days,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            8,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );

        uint256 initialSupply = 1e23;
        uint256 numTokensToSell = 1e23;

        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (bytes32 salt,,) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        vm.startSnapshotGas("Create", "CloneERC20Factory;GovernanceFactory;UniswapV4Initializer;UniswapV2Migrator");
        airlock.create(createParams);
        vm.stopSnapshotGas("Create", "CloneERC20Factory;GovernanceFactory;UniswapV4Initializer;UniswapV2Migrator");
    }
}
