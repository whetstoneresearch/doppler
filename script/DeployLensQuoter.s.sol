// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { Airlock } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";

struct DeployLensQuoterScriptData {
    address poolManager;
    address stateView;
}

contract DeployLensQuoterScript is Script {
    function _deployLensQuoter(IPoolManager poolManager, IStateView stateView) internal returns (DopplerLensQuoter) {
        vm.startBroadcast();
        DopplerLensQuoter quoter = new DopplerLensQuoter(poolManager, stateView);
        vm.stopBroadcast();
        return quoter;
    }

    function run() public {
        console.log(unicode"🚀 Deploying Bundler on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        // Let's check if we have the script data for this chain
        string memory path = "./script/addresses.toml";
        string memory raw = vm.readFile(path);
        bool exists = vm.keyExistsToml(raw, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing script data for chain id", vm.toString(block.chainid)));

        bytes memory data = vm.parseToml(raw, string.concat(".", vm.toString(block.chainid)));
        DeployLensQuoterScriptData memory scriptData = abi.decode(data, (DeployLensQuoterScriptData));

        DopplerLensQuoter quoter =
            _deployLensQuoter(IPoolManager(scriptData.poolManager), IStateView(scriptData.stateView));

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| LensQuoter                 | %s |", address(quoter));
        console.log("+----------------------------+--------------------------------------------+");
    }
}
