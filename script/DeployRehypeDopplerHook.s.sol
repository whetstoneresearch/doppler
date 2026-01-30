// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";

contract DeployRehypeHookScript is Script, Config {
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

        address createX = config.get("create_x").toAddress();
        address dopplerHookInitializer = config.get("doppler_hook_initializer").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(RehypeDopplerHook).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), address(createX));

        address rehypeDopplerHook = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(type(RehypeDopplerHook).creationCode, abi.encode(dopplerHookInitializer, poolManager))
            );
        require(rehypeDopplerHook == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("rehype_doppler_hook", rehypeDopplerHook);
    }
}

