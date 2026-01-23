// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { computeCreate3Address, computeGuardedSalt } from "test/shared/AirlockMiner.sol";

contract DeployAirlockMultisigTestnetScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        targets[0] = ChainIds.ETH_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
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

        // We skip deployment if it already exists
        if (expectedAddress.code.length == 0) {
            address[] memory signers = new address[](5);
            signers[0] = msg.sender;
            signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;
            signers[2] = 0x00D1C1c523D0058359850F8A1E49504ef78541cE;
            signers[3] = 0xdF95Cc445469816234Ad95f702c79d25BCE401a7;
            signers[4] = 0xD877ca966bA431102B6aB217A899fa686D7Fa639;

            address airlockMultisigTestnet = ICreateX(createX)
                .deployCreate3(salt, abi.encodePacked(type(AirlockMultisigTestnet).creationCode, abi.encode(signers)));
            require(airlockMultisigTestnet == expectedAddress, "Unexpected deployed address");
            config.set("airlock_multisig", airlockMultisigTestnet);
        }

        vm.stopBroadcast();
    }
}
