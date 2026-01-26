// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { TokenFactoryV2 } from "src/tokens/TokenFactoryV2.sol";

contract DeployTokenFactoryV2Script is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(TokenFactoryV2).name);
        address predictedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address tokenFactoryV2 = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(TokenFactoryV2).creationCode, abi.encode(airlock)));
        require(tokenFactoryV2 == predictedAddress, "Unexpected deployed address");
        console.log("TokenFactoryV2 deployed to:", tokenFactoryV2);
        vm.stopBroadcast();
    }
}
