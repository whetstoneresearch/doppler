// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { LaunchpadGovernanceFactory } from "src/governance/LaunchpadGovernanceFactory.sol";

abstract contract DeployLaunchpadGovernanceFactory is DeployBase {
    function _deployLaunchpadGovernanceFactory(DeployContext memory context)
        internal
        returns (address launchpadGovernanceFactory)
    {
        bool alreadyDeployed;
        (launchpadGovernanceFactory, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(LaunchpadGovernanceFactory).name,
            LAUNCHPAD_GOVERNANCE_FACTORY_VERSION,
            abi.encodePacked(type(LaunchpadGovernanceFactory).creationCode)
        );

        _verifyLaunchpadGovernanceFactoryDeployment(launchpadGovernanceFactory);
        _setConfigAddress(context, "launchpad_governance_factory", launchpadGovernanceFactory);

        if (alreadyDeployed) {
            console.log("LaunchpadGovernanceFactory already deployed to:", launchpadGovernanceFactory);
        } else {
            console.log("LaunchpadGovernanceFactory deployed to:", launchpadGovernanceFactory);
        }
    }

    function _verifyLaunchpadGovernanceFactoryDeployment(address addr) internal view {
        address multisig = address(0xbeef);
        (bool success, bytes memory result) =
            addr.staticcall(abi.encodeCall(LaunchpadGovernanceFactory.create, (address(0), abi.encode(multisig))));
        require(success, "LaunchpadGovernanceFactory interface check failed");

        (address governance, address timelockController) = abi.decode(result, (address, address));
        require(governance == address(0xdead), "LaunchpadGovernanceFactory governance mismatch");
        require(timelockController == multisig, "LaunchpadGovernanceFactory timelock mismatch");
    }
}

contract DeployLaunchpadGovernanceFactoryScript is DeployLaunchpadGovernanceFactory {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address launchpadGovernanceFactory) {
        return _deployLaunchpadGovernanceFactory(_deployContext());
    }
}

contract DeployLaunchpadGovernanceFactoryScriptEthereum is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployLaunchpadGovernanceFactoryScriptMonad is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployLaunchpadGovernanceFactoryScriptBase is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployLaunchpadGovernanceFactoryScriptBaseSepolia is DeployLaunchpadGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
