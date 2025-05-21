// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolManager } from "src/UniswapV4Initializer.sol";

struct V4ScriptData {
    address airlock;
    address poolManager;
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
        (DopplerDeployer dopplerDeployer, UniswapV4Initializer uniswapV4Initializer) = _deployV4(_scriptData);

        console.log(unicode"✨ Contracts were successfully deployed!");

        console.log("DopplerDeployer: ", address(dopplerDeployer));
        console.log("UniswapV4Initializer: ", address(uniswapV4Initializer));

        vm.stopBroadcast();
    }

    function _deployV4(
        V4ScriptData memory scriptData
    ) internal returns (DopplerDeployer dopplerDeployer, UniswapV4Initializer uniswapV4Initializer) {
        dopplerDeployer = new DopplerDeployer(IPoolManager(scriptData.poolManager));
        uniswapV4Initializer =
            new UniswapV4Initializer(scriptData.airlock, IPoolManager(scriptData.poolManager), dopplerDeployer);
    }
}
