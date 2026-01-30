// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { CloneDERC20VotesV2Factory } from "src/tokens/CloneDERC20VotesV2Factory.sol";

contract DeployCloneDERC20VotesV2FactoryScript is Script, Config {
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

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(CloneDERC20VotesV2Factory).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address factory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(CloneDERC20VotesV2Factory).creationCode, abi.encode(airlock)));
        require(factory == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("clone_derc20_v2_votes_factory", factory);
    }
}
