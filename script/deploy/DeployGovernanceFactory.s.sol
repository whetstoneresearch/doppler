// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";

abstract contract DeployGovernanceFactory is DeployBase {
    function _deployGovernanceFactory(DeployContext memory context) internal returns (address governanceFactory) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployGovernanceFactory(context, airlock);
    }

    function _deployGovernanceFactory(
        DeployContext memory context,
        address airlock
    ) internal returns (address governanceFactory) {
        bytes memory initCode = abi.encodePacked(type(GovernanceFactory).creationCode, abi.encode(airlock));

        bool alreadyDeployed;
        (governanceFactory, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(GovernanceFactory).name, GOVERNANCE_FACTORY_VERSION, initCode
        );

        _verifyGovernanceFactoryDeployment(governanceFactory, airlock);
        _setConfigAddress(context, "governance_factory", governanceFactory);

        if (alreadyDeployed) {
            console.log("GovernanceFactory already deployed to:", governanceFactory);
        } else {
            console.log("GovernanceFactory deployed to:", governanceFactory);
        }
    }

    function _verifyGovernanceFactoryDeployment(address addr, address airlock) internal view {
        GovernanceFactory factory = GovernanceFactory(addr);
        require(address(factory.airlock()) == airlock, "GovernanceFactory airlock mismatch");
        require(address(factory.timelockFactory()) != address(0), "GovernanceFactory timelock factory missing");
    }
}

contract DeployGovernanceFactoryScript is DeployGovernanceFactory {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address governanceFactory) {
        return _deployGovernanceFactory(_deployContext());
    }
}

contract DeployGovernanceFactoryScriptEthereum is DeployGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployGovernanceFactoryScriptMonad is DeployGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployGovernanceFactoryScriptBase is DeployGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployGovernanceFactoryScriptBaseSepolia is DeployGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
