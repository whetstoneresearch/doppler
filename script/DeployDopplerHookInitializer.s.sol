// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MineDopplerHookInitializerParams, mineDopplerHookInitializer } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookInitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](5);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;
        targets[2] = ChainIds.BASE_MAINNET;
        targets[3] = ChainIds.BASE_SEPOLIA;
        targets[4] = ChainIds.MONAD_MAINNET;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        (bytes32 salt, address deployedTo) =
            mineDopplerHookInitializer(MineDopplerHookInitializerParams({ sender: msg.sender, deployer: createX }));
        address dopplerHookInitializer = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager))
            );
        require(dopplerHookInitializer == deployedTo, "Unexpected deployed address");
        vm.stopBroadcast();
        config.set("doppler_hook_initializer", dopplerHookInitializer);
    }
}
