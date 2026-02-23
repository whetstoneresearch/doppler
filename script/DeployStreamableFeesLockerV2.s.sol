// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";

contract DeployStreamableFeesLockerV2Script is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](4);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;
        targets[2] = ChainIds.BASE_MAINNET;
        targets[3] = ChainIds.MONAD_MAINNET;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();
        address owner = config.get("airlock_multisig").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(StreamableFeesLockerV2).name);
        address deployedTo = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address lockerV2 = ICreateX(createX)
            .deployCreate3(
                salt, abi.encodePacked(type(StreamableFeesLockerV2).creationCode, abi.encode(poolManager, owner))
            );

        require(lockerV2 == deployedTo, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("streamable_fees_locker_v2", lockerV2);
    }
}
