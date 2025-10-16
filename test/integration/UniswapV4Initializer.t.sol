// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { Airlock } from "src/Airlock.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import {
    UniswapV2Migrator,
    ILiquidityMigrator,
    IUniswapV2Router02,
    IUniswapV2Factory
} from "src/UniswapV2Migrator.sol";
import {
    UNISWAP_V4_POOL_MANAGER_MAINNET,
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET
} from "test/shared/Addresses.sol";
import {
    DEFAULT_MINIMUM_PROCEEDS,
    DEFAULT_MAXIMUM_PROCEEDS,
    DEFAULT_GAMMA,
    DEFAULT_EPOCH_LENGTH
} from "test/shared/DopplerFixtures.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";

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

contract UniswapV4InitializerIntegrationTest is Test {
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_688_329);

        airlock = new Airlock(address(this));
        (deployer, initializer) =
            deployUniswapV4Initializer(vm, airlock, address(this), UNISWAP_V4_POOL_MANAGER_MAINNET);

        migrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET),
            address(0xb055)
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);
    }

    function test_v4_lifecycle() public {
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
            poolManager: UNISWAP_V4_POOL_MANAGER_MAINNET,
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (bytes32 salt, address hook, address asset) = mineV4(params);

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

        airlock.create(createParams);
    }
}
