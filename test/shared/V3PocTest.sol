// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { UniswapV3Initializer } from "src/initializers/UniswapV3Initializer.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { IUniswapV2Factory, UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";

import {
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET,
    UNISWAP_V3_FACTORY_MAINNET,
    WETH_MAINNET
} from "test/shared/Addresses.sol";

contract V3PocTest is Test {
    UniswapV3Initializer public initializer;
    Airlock public airlock;
    UniswapV2MigratorSplit public uniswapV2LiquidityMigrator;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    TopUpDistributor public topUpDistributor;

    // HAVE ETH_MAINNET_RPC_URL SET IN .env
    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);

        airlock = new Airlock(address(this));
        initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));
        topUpDistributor = new TopUpDistributor(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2MigratorSplit(
            address(airlock), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), topUpDistributor, WETH_MAINNET
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);
    }

    function test_v3_poc() public {
        // TODO: YOUR DOPPLER V3 POC HERE
    }
}
