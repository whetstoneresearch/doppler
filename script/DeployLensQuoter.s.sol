// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";

struct LensQuoterScriptData {
    address poolManager;
    address stateView;
}

abstract contract DeployLensQuoterScript is Script {
    LensQuoterScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(
            unicode"🚀 Deploying LensQuoter on chain %s with sender %s...", vm.toString(block.chainid), msg.sender
        );

        vm.startBroadcast();
        DopplerLensQuoter quoter =
            new DopplerLensQuoter(IPoolManager(_scriptData.poolManager), IStateView(_scriptData.stateView));
        vm.stopBroadcast();

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| LensQuoter                 | %s |", address(quoter));
        console.log("+----------------------------+--------------------------------------------+");
    }
}

contract DeployLensQuoterScriptBase is DeployLensQuoterScript {
    function setUp() public override {
        _scriptData = LensQuoterScriptData({
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            stateView: 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71
        });
    }
}
