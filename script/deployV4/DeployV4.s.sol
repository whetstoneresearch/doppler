// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolManager } from "src/UniswapV4Initializer.sol";

struct V4ScriptData {
    address airlock;
    address poolManager;
    address stateView;
}

/**
 * @title Doppler V4 Deployment Script
 * @notice Use this script if the rest of the protocol (Airlock and co) is already deployed
 */
abstract contract DeployV4Script is Script {
    V4ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying V4 on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        DopplerDeployer dopplerDeployer = new DopplerDeployer(IPoolManager(_scriptData.poolManager));
        UniswapV4Initializer uniswapV4Initializer =
            new UniswapV4Initializer(_scriptData.airlock, IPoolManager(_scriptData.poolManager), dopplerDeployer);
        // DopplerLensQuoter quoter =
        //  new DopplerLensQuoter(IPoolManager(_scriptData.poolManager), IStateView(_scriptData.stateView));

        console.log(unicode"✨ Contracts were successfully deployed!");

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| UniswapV4Initializer       | %s |", address(uniswapV4Initializer));
        console.log("| DopplerDeployer            | %s |", address(dopplerDeployer));
        // console.log("| DopplerLensQuoter          | %s |", address(quoter));
        console.log("+----------------------------+--------------------------------------------+");

        vm.stopBroadcast();
    }
}
