// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";

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

        address createX = config.get("create_x").toAddress();
        address dopplerHookInitializer = config.get("doppler_hook_initializer").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        bytes32 salt = bytes32(hex"beefbeef");

        vm.startBroadcast();
        address rehypeDopplerHook = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(type(RehypeDopplerHook).creationCode, abi.encode(dopplerHookInitializer, poolManager))
            );

        console.log("rehypeDopplerHook deployed to:", rehypeDopplerHook);
        config.set("rehype_doppler_hook", rehypeDopplerHook);
        vm.stopBroadcast();
    }
}

