// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { LaunchpadGovernanceFactory } from "src/modules/governance/LaunchpadGovernanceFactory.sol";

struct ScriptData {
    uint256 chainId;
}

abstract contract DeployLaunchpadGovernanceFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(block.chainid == _scriptData.chainId, "Invalid chainId");
        new LaunchpadGovernanceFactory();
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployLaunchpadGovernanceFactoryBaseScript --private-key $PRIVATE_KEY --broadcast --slow --verify --rpc-url $BASE_MAINNET_RPC_URL
contract DeployLaunchpadGovernanceFactoryBaseScript is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: ChainIds.BASE_MAINNET });
    }
}

/// @dev forge script DeployLaunchpadGovernanceFactoryBaseSepoliaScript --private-key $PRIVATE_KEY --broadcast --slow --verify --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployLaunchpadGovernanceFactoryBaseSepoliaScript is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: ChainIds.BASE_SEPOLIA });
    }
}

/// @dev forge script DeployLaunchpadGovernanceFactoryMonadTestnetScript --private-key $PRIVATE_KEY --broadcast --slow --verify --rpc-url $MONAD_TESTNET_RPC_URL
contract DeployLaunchpadGovernanceFactoryMonadTestnetScript is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: ChainIds.MONAD_TESTNET });
    }
}

