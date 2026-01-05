// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import {
    MineDopplerHookInitializerCreate2Params,
    MineDopplerHookInitializerParams,
    mineDopplerHookInitializer,
    mineDopplerHookInitializerCreate2
} from "test/shared/AirlockMiner.sol";

contract ComputeDopplerHookInitializerSaltScript is Script, Config {
    function run() public {
        address createX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
        address sender = address(0xaCE07c3c1D3b556D42633211f0Da71dc6F6d1c42);

        (bytes32 salt, address deployedTo) =
            mineDopplerHookInitializer(MineDopplerHookInitializerParams({ sender: sender, deployer: createX }));

        console.log("Computed salt:");
        console.logBytes32(salt);
    }
}

// FIXME: We cannot use this script because the DopplerHookInitializer contract has a linked library
contract DeployDopplerHookInitializerMultichainScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToTestnetChain(chainId);
        }
    }

    function deployToTestnetChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        bytes32 salt = 0xace07c3c1d3b556d42633211f0da71dc6f6d1c420000000000000000000014dd;

        vm.startBroadcast();
        address dopplerHookInitializer = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager))
            );

        console.log("DopplerHookInitializer deployed to:", dopplerHookInitializer);
        config.set("doppler_hook_initializer", dopplerHookInitializer);
        vm.stopBroadcast();
    }
}

contract DeployDopplerHookInitializerScript is Script, Config {
    function run() public {
        _loadConfig("./deployments.config.toml", true);

        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        bytes32 salt = 0xace07c3c1d3b556d42633211f0da71dc6f6d1c420000000000000000000014dd;

        vm.startBroadcast();
        address dopplerHookInitializer = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager))
            );

        console.log("DopplerHookInitializer deployed to:", dopplerHookInitializer);
        config.set("doppler_hook_initializer", dopplerHookInitializer);
        vm.stopBroadcast();
    }
}

contract MineDopplerHookInitializerSalt is Script {
    function run() public {
        address airlock = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
        address poolManager = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (bytes32 salt, address deployedTo) = mineDopplerHookInitializerCreate2(
            MineDopplerHookInitializerCreate2Params({
                deployer: create2Factory, airlock: airlock, poolManager: poolManager
            })
        );

        console.log("Salt");
        console.logBytes32(salt);
    }
}

contract DeployDopplerHookInitializerBaseSepoliaScript is Script {
    function run() public {
        address airlock = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
        address poolManager = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        bytes32 salt = 0x00000000000000000000000000000000000000000000000000000000000014bc;

        vm.startBroadcast();
        DopplerHookInitializer dopplerHookInitializer =
            new DopplerHookInitializer{ salt: salt }(airlock, IPoolManager(poolManager));
        vm.stopBroadcast();
        console.log("DopplerHookInitializer deployed to:", address(dopplerHookInitializer));
    }
}
