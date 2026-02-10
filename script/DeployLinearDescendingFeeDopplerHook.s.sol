// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { LinearDescendingFeeDopplerHook } from "src/dopplerHooks/LinearDescendingFeeDopplerHook.sol";

contract DeployLinearDescendingFeeDopplerHookScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](5);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;
        targets[2] = ChainIds.BASE_MAINNET;
        targets[3] = ChainIds.BASE_SEPOLIA;
        targets[4] = ChainIds.MONAD_MAINNET;

        for (uint256 i; i < targets.length; i++) {
            deployToChain(targets[i]);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();
        address dopplerHookInternalInitializer = config.get("doppler_hook_internal_initializer").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(LinearDescendingFeeDopplerHook).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), address(createX));

        address hook = ICreateX(createX).deployCreate3(
            salt,
            abi.encodePacked(
                type(LinearDescendingFeeDopplerHook).creationCode, abi.encode(dopplerHookInternalInitializer)
            )
        );
        require(hook == expectedAddress, "Unexpected deployed address");
        vm.stopBroadcast();

        config.set("linear_descending_fee_doppler_hook", hook);
    }
}
