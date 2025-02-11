// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";

struct Addresses {
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
}

contract V1DeploymentScript is Script {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;

    function run() public {
        string memory path = "./script/addresses.json";
        string memory json = vm.readFile(path);
        bool exists = vm.keyExistsJson(json, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing Uniswap addresses for chain with id ", vm.toString(block.chainid)));

        bytes memory data = vm.parseJson(json, string.concat(".", vm.toString(block.chainid)));
        Addresses memory addresses = abi.decode(data, (Addresses));

        console.log("uniswapV2Router02 %s", addresses.uniswapV2Router02);
        console.log("uniswapV2Factory %s", addresses.uniswapV2Factory);
        console.log("uniswapV3Factory %s", addresses.uniswapV3Factory);

        address owner = vm.envOr("PROTOCOL_OWNER", address(0));
        require(owner != address(0), "PROTOCOL_OWNER not set! Please edit your .env file.");
        console.log(unicode"👑 PROTOCOL_OWNER set as %s", owner);

        vm.startBroadcast();
        console.log(unicode"🚀 Deploying contracts...");

        // Owner of the protocol is set as the deployer to allow the whitelisting of modules, ownership
        // is then transferred
        airlock = new Airlock(msg.sender);
        tokenFactory = new TokenFactory(address(airlock));
        uniswapV3Initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(addresses.uniswapV3Factory));
        governanceFactory = new GovernanceFactory(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(addresses.uniswapV2Factory),
            IUniswapV2Router02(addresses.uniswapV2Router02),
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

        airlock.transferOwnership(owner);

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

        // Some checks to ensure that the deployment was successful
        for (uint256 i; i < modules.length; i++) {
            require(airlock.getModuleState(modules[i]) == states[i], "Module state not set correctly");
        }
        require(address(tokenFactory.airlock()) == address(airlock), "TokenFactory not set correctly");
        require(address(uniswapV3Initializer.airlock()) == address(airlock), "UniswapV3Initializer not set correctly");
        require(address(governanceFactory.airlock()) == address(airlock), "GovernanceFactory not set correctly");
        require(
            address(uniswapV2LiquidityMigrator.airlock()) == address(airlock),
            "UniswapV2LiquidityMigrator not set correctly"
        );
        require(airlock.owner() == owner, "Ownership not transferred to PROTOCOL_OWNER");
    }
}
