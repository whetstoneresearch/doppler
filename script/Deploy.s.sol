// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";

import { NoOpGovernanceFactory } from "src/modules/governance/NoOpGovernanceFactory.sol";
import {
    UniswapV4ScheduledMulticurveInitializer
} from "src/modules/initializers/UniswapV4ScheduledMulticurveInitializer.sol";
import { NoOpMigrator } from "src/modules/migrators/NoOpMigrator.sol";

contract DeployScript is Script, Config {
    NoOpMigrator public noOpMigrator;
    NoOpGovernanceFactory public noOpGovernanceFactory;
    UniswapV4ScheduledMulticurveInitializer public uniswapV4ScheduledMulticurveInitializer;

    function run() public {
        _loadConfig("./deployments.toml", true);

        uint256 chainId = block.chainid;
        console.log("Deploying to chainId:", chainId);

        vm.startBroadcast();

        vm.stopBroadcast();
    }
}
