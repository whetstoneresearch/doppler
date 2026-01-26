// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt } from "script/utils/CreateX.sol";
import { Airlock } from "src/Airlock.sol";

contract DeployAirlockScript is Script, Config {
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
        address multisig = config.get("airlock_multisig").toAddress();

        vm.startBroadcast();
        bytes32 salt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xb16b055));
        address predictedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address airlock =
            ICreateX(createX).deployCreate3(salt, abi.encodePacked(type(Airlock).creationCode, abi.encode(multisig)));
        require(airlock == predictedAddress, "Unexpected deployed address");

        config.set("airlock", airlock);
        vm.stopBroadcast();
    }
}
