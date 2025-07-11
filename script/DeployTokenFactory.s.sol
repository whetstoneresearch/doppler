// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { TokenFactory } from "src/TokenFactory.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
}

abstract contract DeployTokenFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(block.chainid == _scriptData.chainId, "Invalid chainId");
        TokenFactory tokenFactory = new TokenFactory(_scriptData.airlock);
        vm.stopBroadcast();
    }
}

contract DeployTokenFactoryBaseScript is DeployTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: 8453, airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12 });
    }
}

contract DeployTokenFactoryBaseSepoliaScript is DeployTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ chainId: 84_532, airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e });
    }
}
