// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { computeCreate3Address, computeGuardedSalt } from "test/shared/AirlockMiner.sol";

contract DeployAirlockMultisigTestnetScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToTestnetChain(chainId);
        }
    }

    function deployToTestnetChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        // We only deploy this multisig on testnets
        if (config.get("is_testnet").toBool() == false) {
            return;
        }

        address createX = config.get("create_x").toAddress();

        vm.startBroadcast();

        bytes32 salt = bytes32(uint256(uint160(msg.sender)) << 96 | 0xdeadbeef);
        address expectedAddress = computeCreate3Address(computeGuardedSalt(salt, msg.sender), address(createX));

        address[] memory signers = new address[](2);
        signers[0] = msg.sender;
        signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;

        address airlockMultisigTestnet = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(AirlockMultisigTestnet).creationCode, abi.encode(signers)));
        require(airlockMultisigTestnet == expectedAddress, "Unexpected deployed address");
        console.log("AirlockMultisigTestnet deployed to:", airlockMultisigTestnet);
        config.set("airlock_multisig", airlockMultisigTestnet);
        vm.stopBroadcast();
    }
}
