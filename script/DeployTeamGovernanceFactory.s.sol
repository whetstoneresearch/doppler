// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { TeamGovernanceFactory } from "src/TeamGovernanceFactory.sol";

struct ScriptData {
    uint256 chainId;
}

abstract contract DeployTeamGovernanceFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(block.chainid == _scriptData.chainId, "Invalid chainId");
        TeamGovernanceFactory teamGovernanceFactory = new TeamGovernanceFactory();
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployTeamGovernanceFactoryBaseScript --private-key $PRIVATE_KEY --broadcast --slow --verify --rpc-url $BASE_MAINNET_RPC_URL
contract DeployTeamGovernanceFactoryBaseScript is DeployTeamGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: 8453 });
    }
}

/// @dev forge script DeployTeamGovernanceFactoryBaseScript --private-key $PRIVATE_KEY --broadcast --slow --verify --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployTeamGovernanceFactoryBaseSepoliaScript is DeployTeamGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: 84_532 });
    }
}
