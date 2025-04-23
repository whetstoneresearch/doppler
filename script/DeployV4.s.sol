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
contract DeployV4Script is Script {
    function run() public {
        console.log(unicode"🚀 Deploying V4 on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Let's check if we have the script data for this chain
        string memory path = "./script/addresses.toml";
        string memory raw = vm.readFile(path);
        bool exists = vm.keyExistsToml(raw, string.concat(".", vm.toString(block.chainid)));
        require(exists, string.concat("Missing script data for chain id", vm.toString(block.chainid)));

        bytes memory data = vm.parseToml(raw, string.concat(".", vm.toString(block.chainid)));
        V4ScriptData memory scriptData = abi.decode(data, (V4ScriptData));

        UniswapV4Initializer uniswapV4Initializer = _deployV4(scriptData);

        console.log(unicode"✨ UniswapV4Initializer was successfully deployed at %s!", address(uniswapV4Initializer));

        vm.stopBroadcast();
    }

    function _deployV4(
        V4ScriptData memory scriptData
    ) internal returns (UniswapV4Initializer uniswapV4Initializer) {
        DopplerDeployer dopplerDeployer = new DopplerDeployer(IPoolManager(scriptData.poolManager));
        uniswapV4Initializer =
            new UniswapV4Initializer(scriptData.airlock, IPoolManager(scriptData.poolManager), dopplerDeployer);
    }
}
