// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MineDopplerHookInitializerParams, mineDopplerHookInitializer } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookInitializerMultichainScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            if (chainIds[i] != 6343) {
                uint256 chainId = chainIds[i];
                deployToTestnetChain(chainId);
            }
        }
    }

    function deployToTestnetChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        // TODO: Remove this to deploy to production
        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        (bytes32 salt, address deployedTo) = mineDopplerHookInitializer(
            MineDopplerHookInitializerParams({ sender: msg.sender, deployer: address(createX) })
        );
        address dopplerHookInitializer = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager))
            );
        require(dopplerHookInitializer == deployedTo, "Unexpected deployed address");
        console.log("DopplerHookInitializer deployed to:", dopplerHookInitializer);
        config.set("doppler_hook_initializer", dopplerHookInitializer);
        vm.stopBroadcast();
    }
}
