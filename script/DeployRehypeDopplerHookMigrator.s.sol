// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";

contract DeployRehypeHookMigratorScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        targets[0] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();
        address migrator = config.get("doppler_hook_migrator").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(RehypeDopplerHookMigrator).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), address(createX));

        address rehypeDopplerHookMigrator = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(RehypeDopplerHookMigrator).creationCode, abi.encode(migrator, poolManager))
            );
        require(rehypeDopplerHookMigrator == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("rehype_doppler_hook_migrator", rehypeDopplerHookMigrator);
    }
}

