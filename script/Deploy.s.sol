// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { NoOpGovernanceFactory } from "src/modules/governance/NoOpGovernanceFactory.sol";
import {
    UniswapV4ScheduledMulticurveInitializer
} from "src/modules/initializers/UniswapV4ScheduledMulticurveInitializer.sol";
import { NoOpMigrator } from "src/modules/migrators/NoOpMigrator.sol";

contract DeployScript2 is Script, Config {
    NoOpMigrator public noOpMigrator;
    NoOpGovernanceFactory public noOpGovernanceFactory;
    UniswapV4ScheduledMulticurveInitializer public uniswapV4ScheduledMulticurveInitializer;

    function run() public {
        _loadConfigAndForks("./deployments.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            console.log("Loaded chain %s", chainIds[i]);
        }

        vm.startBroadcast();

        // TODO: Deploy all of our contracts here

        // _checkAndDeploy("pool_manager");

        vm.stopBroadcast();
    }

    function _checkAndDeploy(string memory contractName) internal returns (address deployedAddress) {
        deployedAddress = config.get(contractName).toAddress();

        if (deployedAddress == address(0)) {
            console.log("Deploying %s...", contractName);
        }
    }
}
