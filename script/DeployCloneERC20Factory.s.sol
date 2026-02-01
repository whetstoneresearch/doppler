// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";

contract DeployCloneERC20FactoryScript is Script, Config {
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
        bytes32 salt = generateCreate3Salt(msg.sender, type(CloneERC20Factory).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address cloneERC20Factory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(CloneERC20Factory).creationCode, abi.encode(airlock)));
        require(cloneERC20Factory == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("clone_erc20_factory", cloneERC20Factory);
    }
}
