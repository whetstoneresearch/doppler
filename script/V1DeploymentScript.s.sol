// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";

address constant UNICHAIN_SEPOLIA_UNISWAP_V2_ROUTER_02 = 0x920b806E40A00E02E7D2b94fFc89860fDaEd3640;
address constant UNICHAIN_SEPOLIA_UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
address constant UNICHAIN_SEPOLIA_UNISWAP_v3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

contract V1DeploymentScript is Script {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;

    function run() public {
        address owner = vm.envOr("PROTOCOL_OWNER", address(0));
        require(owner != address(0), "PROTOCOL_OWNER not set! Please edit your .env file.");
        console.log(unicode"👑 PROTOCOL_OWNER set as %s", owner);

        vm.startBroadcast();
        console.log(unicode"🚀 Deploying contracts...");

        airlock = new Airlock(owner);
        tokenFactory = new TokenFactory(address(airlock));
        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(UNICHAIN_SEPOLIA_UNISWAP_v3_FACTORY));
        governanceFactory = new GovernanceFactory(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(UNICHAIN_SEPOLIA_UNISWAP_V2_FACTORY),
            IUniswapV2Router02(UNICHAIN_SEPOLIA_UNISWAP_V2_ROUTER_02),
            owner
        );

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);

        console.log(unicode"✨ Contracts were successfully deployed:");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Airlock                    | %s |", address(airlock));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| TokenFactory               | %s |", address(tokenFactory));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV3Initializer       | %s |", address(uniswapV3Initializer));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| GovernanceFactory          | %s |", address(governanceFactory));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV2LiquidityMigrator | %s |", address(uniswapV2LiquidityMigrator));
        console.log("+----------------------------+--------------------------------------------+");

        vm.stopBroadcast();
    }
}
