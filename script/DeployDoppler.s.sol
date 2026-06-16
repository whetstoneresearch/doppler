// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployAirlock } from "script/deploy/DeployAirlock.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";

contract DeployDopplerScript is DeployAirlock {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public {
        _deployAirlock(_deployContext());
        // TODO: Revise remaining deployment scripts to follow the patterns established in DeployDeployerScript and DeployAirlockScript
        // Then update this script to call each of the remaining deployment scripts for all contracts specified in Versions.sol
    }
}

contract DeployDopplerScriptEthereum is DeployDopplerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET);
    }
}

contract DeployDopplerScriptMonad is DeployDopplerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET);
    }
}

contract DeployDopplerScriptBase is DeployDopplerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET);
    }
}

contract DeployDopplerScriptBaseSepolia is DeployDopplerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA);
    }
}
