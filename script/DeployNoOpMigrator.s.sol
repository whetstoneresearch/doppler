// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
}

abstract contract DeployNoOpMigratorScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(_scriptData.airlock != address(0), "Airlock address not set");
        require(block.chainid == _scriptData.chainId, "Incorrect chainId");
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();
        vm.stopBroadcast();
    }
}

contract DeployNoOpMigratorBaseScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12, chainId: 8453 });
    }
}

contract DeployNoOpMigratorBaseSepoliaScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({ airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e, chainId: 84_532 });
    }
}
