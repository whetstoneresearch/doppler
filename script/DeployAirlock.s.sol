// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { Airlock } from "src/Airlock.sol";
import { computeCreate3Address, efficientHash } from "test/shared/AirlockMiner.sol";

contract DeployAirlockScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Right now we're only deploying to MegaETH chains since Airlock is already deployed on others
            // MegaETH Mainnet 4326
            // MegaETH Testnet 6343
            if (chainId == 6343 || chainId == 4326) {
                deployToChain(chainId);
            }
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();
        address multisig = config.get("airlock_multisig").toAddress();

        vm.startBroadcast();
        bytes32 salt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xb16b055));
        bytes32 guardedSalt = efficientHash({ a: bytes32(uint256(uint160(msg.sender))), b: salt });

        address predictedAddress = computeCreate3Address(guardedSalt, createX);

        address airlock =
            ICreateX(createX).deployCreate3(salt, abi.encodePacked(type(Airlock).creationCode, abi.encode(multisig)));
        require(airlock == predictedAddress, "Unexpected deployed address");

        console.log("Airlock deployed to:", airlock);
        config.set("airlock", airlock);
        vm.stopBroadcast();
    }
}
