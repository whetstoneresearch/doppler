// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { computeCreate3Address, efficientHash } from "test/shared/AirlockMiner.sol";

contract DeployRehypeHookScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        // TODO: Remove this to deploy to production
        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address createX = config.get("create_x").toAddress();
        address dopplerHookInitializer = config.get("doppler_hook_initializer").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        bytes32 salt = bytes32(uint256(uint160(msg.sender)) << 96 | 0x12345);
        address expectedAddress = computeCreate3Address(
            efficientHash({ a: bytes32(uint256(uint160(msg.sender))), b: salt }), address(createX)
        );

        address rehypeDopplerHook = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(type(RehypeDopplerHook).creationCode, abi.encode(dopplerHookInitializer, poolManager))
            );
        require(rehypeDopplerHook == expectedAddress, "Unexpected deployed address");

        console.log("rehypeDopplerHook deployed to:", rehypeDopplerHook);
        config.set("rehype_doppler_hook", rehypeDopplerHook);
        vm.stopBroadcast();
    }
}

