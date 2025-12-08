// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MineDopplerHookInitializerParams, mineDopplerHookInitializer } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookInitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        (bytes32 salt, address deployedTo) = mineDopplerHookInitializer(
            MineDopplerHookInitializerParams({
                airlock: airlock, poolManager: poolManager, sender: msg.sender, deployer: createX
            })
        );

        vm.startBroadcast();
        address dopplerHookInitializer = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager))
            );

        console.log("DopplerHookInitializer deployed to:", dopplerHookInitializer);
        // config.set("doppler_hook_initializer", dopplerHookInitializer);
        vm.stopBroadcast();
    }
}
