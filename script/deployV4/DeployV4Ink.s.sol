// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployV4Script, V4ScriptData } from "script/deployV4/DeployV4.s.sol";

contract DeployV4Ink is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
            stateView: 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990
        });
    }
}
