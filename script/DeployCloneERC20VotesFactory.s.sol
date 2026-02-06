// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { CloneERC20VotesFactory } from "src/tokens/CloneERC20VotesFactory.sol";

contract DeployCloneERC20VotesFactoryScript is Script, Config {
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

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(CloneERC20VotesFactory).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address cloneERC20VotesFactory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(CloneERC20VotesFactory).creationCode, abi.encode(airlock)));
        require(cloneERC20VotesFactory == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("clone_erc20_votes_factory", cloneERC20VotesFactory);
    }
}
