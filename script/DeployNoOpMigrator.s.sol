// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt } from "script/utils/CreateX.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";

contract DeployNoOpMigratorScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](2);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();
        address airlock = config.get("airlock").toAddress();

        vm.startBroadcast();
        bytes32 salt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xdeaddeaddeaddead));
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address noOpMigrator = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(NoOpMigrator).creationCode, abi.encode(airlock)));
        require(noOpMigrator == expectedAddress, "Unexpected deployed address");

        config.set("no_op_migrator", noOpMigrator);
        vm.stopBroadcast();
    }
}
