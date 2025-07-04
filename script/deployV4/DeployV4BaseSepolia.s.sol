// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployV4Script, V4ScriptData } from "script/deployV4/DeployV4.s.sol";

contract DeployV4BaseSepolia is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4
        });
    }
}
