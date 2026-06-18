// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { ChainIds } from "script/utils/ChainIds.sol";

abstract contract DeployAirlockMultisigTestnet is DeployBase {
    bytes32 public airlockMultisigSalt; // Only set if you want to use a specific salt
    address public airlockMultisigExpectedAddress; // Only set if you've configured a custom salt

    function _deployAirlockMultisigTestnet(DeployContext memory context)
        internal
        returns (address airlockMultisigTestnet)
    {
        address[] memory signers = _airlockMultisigTestnetSigners();
        bytes memory initCode = abi.encodePacked(type(AirlockMultisigTestnet).creationCode, abi.encode(signers));

        bool alreadyDeployed;
        (airlockMultisigTestnet, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            airlockMultisigSalt,
            airlockMultisigExpectedAddress,
            type(AirlockMultisigTestnet).name,
            AIRLOCK_MULTISIG_VERSION,
            initCode
        );

        _verifyAirlockMultisigTestnetDeployment(airlockMultisigTestnet, signers);
        _setConfigAddress(context, "airlock_multisig", airlockMultisigTestnet);

        if (alreadyDeployed) {
            console.log("AirlockMultisigTestnet already deployed to:", airlockMultisigTestnet);
        } else {
            console.log("AirlockMultisigTestnet deployed to:", airlockMultisigTestnet);
        }
    }

    // TODO: Clean this up, verify all signers are current and valid
    function _airlockMultisigTestnetSigners() internal pure returns (address[] memory signers) {
        signers = new address[](8);
        signers[0] = 0xaCE07c3c1D3b556D42633211f0Da71dc6F6d1c42;
        signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;
        signers[2] = 0x00D1C1c523D0058359850F8A1E49504ef78541cE;
        signers[3] = 0xdF95Cc445469816234Ad95f702c79d25BCE401a7;
        signers[4] = 0xD877ca966bA431102B6aB217A899fa686D7Fa639;
        signers[5] = 0x38013363908d329749e5a47B391DB5f85A1eE969;
        signers[6] = 0x97a90100d77D05E309cdeB7e2AaF91F0EF8CA5ac;
        signers[7] = 0xF7608C49Fd0B21BD8bd1B24BBa456061ABa0F427;
    }

    function _verifyAirlockMultisigTestnetDeployment(address addr, address[] memory signers) internal view {
        AirlockMultisigTestnet multisig = AirlockMultisigTestnet(addr);
        for (uint256 i; i < signers.length; i++) {
            require(multisig.isSigner(signers[i]), "AirlockMultisigTestnet signer mismatch");
        }
    }
}

contract DeployAirlockMultisigTestnetScript is DeployAirlockMultisigTestnet {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        if (!_isConfiguredTestnet(block.chainid)) {
            console.log("Skipping AirlockMultisigTestnet deployment for non-testnet chain:", block.chainid);
            return;
        }

        deploy();
    }

    function deploy() public returns (address airlockMultisigTestnet) {
        require(_isConfiguredTestnet(block.chainid), "AirlockMultisigTestnet only deploys on testnets");
        return _deployAirlockMultisigTestnet(_deployContext());
    }
}

contract DeployAirlockMultisigTestnetScriptBaseSepolia is DeployAirlockMultisigTestnetScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
