// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { LibString } from "solady/utils/LibString.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { MineDopplerHookInitializerParams, mineDopplerHookInitializer } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookInitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](4);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.MONAD_MAINNET;
        targets[2] = ChainIds.BASE_MAINNET;
        targets[3] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            vm.selectFork(forkOf[chainId]);
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
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

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("doppler_hook_initializer", dopplerHookInitializer);
        }
        console.log(
            "DopplerHookInitializer was deployed to",
            LibString.toHexString(uint256(uint160(dopplerHookInitializer))),
            "on chain ID",
            LibString.toString(chainId)
        );
    }
}
