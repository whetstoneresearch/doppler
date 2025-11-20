// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { GovernanceFactory } from "src/modules/governance/GovernanceFactory.sol";

struct ScriptData {
    address airlock;
}

abstract contract DeployGovernanceFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        GovernanceFactory governanceFactory = new GovernanceFactory(_scriptData.airlock);

        console.log(unicode"✨ GovernanceFactory was successfully deployed!");
        console.log("GovernanceFactory address: %s", address(governanceFactory));

        vm.stopBroadcast();
    }
}

contract DeployGovernanceFactoryBaseScript is DeployGovernanceFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12 });
    }
}
