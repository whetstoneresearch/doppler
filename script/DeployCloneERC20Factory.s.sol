// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";

struct ScriptData {
    address airlock;
}

abstract contract DeployCloneERC20FactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        new CloneERC20Factory(_scriptData.airlock);
        vm.stopBroadcast();
    }
}
