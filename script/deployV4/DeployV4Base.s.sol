// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployV4Script, V4ScriptData } from "script/deployV4/DeployV4.s.sol";

contract DeployV4Base is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            stateView: 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71
        });
    }
}
