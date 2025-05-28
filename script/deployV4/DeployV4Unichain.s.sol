// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployV4Script, V4ScriptData } from "script/deployV4/DeployV4.s.sol";

contract DeployV4Unichain is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            stateView: 0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2
        });
    }
}
