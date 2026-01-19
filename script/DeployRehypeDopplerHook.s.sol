// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";

contract DeployRehypeHookScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        targets[0] = 84_532;
        targets[1] = 1301;

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

        console.log("rehypeDopplerHook deployed to:", rehypeDopplerHook);
        config.set("rehype_doppler_hook", rehypeDopplerHook);
        vm.stopBroadcast();
    }
}

