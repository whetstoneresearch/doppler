// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock } from "src/Airlock.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IStateView } from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

contract DeployLensQuoterScript is Script {
    IPoolManager constant POOLMANAGER = IPoolManager(address(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408));
    IStateView constant STATE_VIEW = IStateView(address(0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4));

    function run() public {
        vm.startBroadcast();
        DopplerLensQuoter lensQuoter = new DopplerLensQuoter(IPoolManager(POOLMANAGER), STATE_VIEW);

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| LensQuoter                 | %s |", address(lensQuoter));
        console.log("+----------------------------+--------------------------------------------+");
        vm.stopBroadcast();
    }
}
