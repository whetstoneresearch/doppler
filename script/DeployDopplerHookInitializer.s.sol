// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MineDopplerHookInitializerParams, mineDopplerHookInitializer } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookInitializerScript is Script, Config {
    function run() public {
        _loadConfig("./deployments.config.toml", true);

        address airlock = config.get("airlock").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        (bytes32 salt, address deployedTo) = mineDopplerHookInitializer(
            MineDopplerHookInitializerParams({ airlock: airlock, poolManager: poolManager, deployer: msg.sender })
        );

        vm.startBroadcast();
        DopplerHookInitializer dopplerHookInitializer =
            new DopplerHookInitializer{ salt: salt }(airlock, IPoolManager(poolManager));
        vm.stopBroadcast();
    }
}
