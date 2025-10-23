// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { Airlock } from "src/Airlock.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";
import { ChainIds } from "script/ChainIds.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
    address[] signers;
}

abstract contract DeployAirlockMultisigScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(_scriptData.chainId == block.chainid, "Incorrect chainId");
        AirlockMultisig multisig = new AirlockMultisig(Airlock(payable(_scriptData.airlock)), _scriptData.signers);
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployAirlockMultisigBaseSepoliaScript --private-key $PRIVATE_KEY --verify --rpc-url $BASE_SEPOLIA_RPC_URL --slow --broadcast
contract DeployAirlockMultisigBaseSepoliaScript is DeployAirlockMultisigScript {
    function setUp() public override {
        address[] memory signers = new address[](2);
        signers[0] = msg.sender;
        signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;

        _scriptData = ScriptData({
            chainId: ChainIds.BASE_SEPOLIA, airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e, signers: signers
        });
    }
}

/// @dev forge script DeployAirlockMultisigUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --slow --broadcast
contract DeployAirlockMultisigUnichainSepoliaScript is DeployAirlockMultisigScript {
    function setUp() public override {
        address[] memory signers = new address[](2);
        signers[0] = msg.sender;
        signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;

        _scriptData = ScriptData({ chainId: ChainIds.UNICHAIN_SEPOLIA, airlock: address(0), signers: signers });
    }
}

/// @dev forge script DeployAirlockMultisigMonadTestnetScript --private-key $PRIVATE_KEY --verify --rpc-url $MONAD_TESTNET_RPC_URL --slow --broadcast
contract DeployAirlockMultisigMonadTestnetScript is DeployAirlockMultisigScript {
    function setUp() public override {
        address[] memory signers = new address[](2);
        signers[0] = msg.sender;
        signers[1] = 0x88C23B886580FfAd04C66055edB6c777f5F74a08;

        _scriptData = ScriptData({
            chainId: ChainIds.MONAD_TESTNET, airlock: 0xa82c66b6ddEb92089015C3565E05B5c9750b2d4B, signers: signers
        });
    }
}
