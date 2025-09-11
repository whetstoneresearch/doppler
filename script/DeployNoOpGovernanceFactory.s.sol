// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { ChainIds } from "script/ChainIds.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
}

abstract contract DeployNoOpGovernanceFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.chainId == block.chainid, "Invalid chainId");
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        console.log(unicode"✨ NoOpGovernanceFactory was successfully deployed!");
        console.log("NoOpGovernanceFactory address: %s", address(noOpGovernanceFactory));

        vm.stopBroadcast();
    }
}

contract DeployNoOpGovernanceFactoryBaseScript is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12, chainId: ChainIds.BASE_MAINNET });
    }
}

contract DeployNoOpGovernanceFactoryBaseSepoliaScript is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e, chainId: ChainIds.BASE_SEPOLIA });
    }
}

/// @dev forge script DeployNoOpGovernanceFactoryUnichainScript --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_MAINNET_RPC_URL --slow --broadcast
contract DeployNoOpGovernanceFactoryUnichainScript is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254, chainId: ChainIds.UNICHAIN_MAINNET });
    }
}

/// @dev forge script DeployNoOpGovernanceFactoryUnichainSepolia --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --slow --broadcast
contract DeployNoOpGovernanceFactoryUnichainSepolia is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF, chainId: ChainIds.UNICHAIN_SEPOLIA });
    }
}
