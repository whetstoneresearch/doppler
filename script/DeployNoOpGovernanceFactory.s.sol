// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";

struct ScriptData {
    address airlock;
}

abstract contract DeployNoOpGovernanceFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
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
        _scriptData = ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12 });
    }
}