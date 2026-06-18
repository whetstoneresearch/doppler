// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";

abstract contract DeployNoOpGovernanceFactory is DeployBase {
    function _deployNoOpGovernanceFactory(DeployContext memory context)
        internal
        returns (address noOpGovernanceFactory)
    {
        bool alreadyDeployed;
        (noOpGovernanceFactory, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(NoOpGovernanceFactory).name,
            NO_OP_GOVERNANCE_FACTORY_VERSION,
            abi.encodePacked(type(NoOpGovernanceFactory).creationCode)
        );

        _verifyNoOpGovernanceFactoryDeployment(noOpGovernanceFactory);
        _setConfigAddress(context, "no_op_governance_factory", noOpGovernanceFactory);

        if (alreadyDeployed) {
            console.log("NoOpGovernanceFactory already deployed to:", noOpGovernanceFactory);
        } else {
            console.log("NoOpGovernanceFactory deployed to:", noOpGovernanceFactory);
        }
    }

    function _verifyNoOpGovernanceFactoryDeployment(address addr) internal view {
        require(NoOpGovernanceFactory(addr).DEAD_ADDRESS() == address(0xdead), "NoOpGovernanceFactory mismatch");
    }
}

contract DeployNoOpGovernanceFactoryScript is DeployNoOpGovernanceFactory {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address noOpGovernanceFactory) {
        return _deployNoOpGovernanceFactory(_deployContext());
    }
}

contract DeployNoOpGovernanceFactoryScriptEthereum is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployNoOpGovernanceFactoryScriptMonad is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployNoOpGovernanceFactoryScriptBase is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployNoOpGovernanceFactoryScriptBaseSepolia is DeployNoOpGovernanceFactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
