// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";

abstract contract DeployNoOpMigrator is DeployBase {
    function _deployNoOpMigrator(DeployContext memory context) internal returns (address noOpMigrator) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployNoOpMigrator(context, airlock);
    }

    function _deployNoOpMigrator(
        DeployContext memory context,
        address airlock
    ) internal returns (address noOpMigrator) {
        bytes memory initCode = abi.encodePacked(type(NoOpMigrator).creationCode, abi.encode(airlock));

        bool alreadyDeployed;
        (noOpMigrator, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(NoOpMigrator).name, NO_OP_MIGRATOR_VERSION, initCode
        );

        _verifyNoOpMigratorDeployment(noOpMigrator, airlock);
        _setConfigAddress(context, "no_op_migrator", noOpMigrator);

        if (alreadyDeployed) {
            console.log("NoOpMigrator already deployed to:", noOpMigrator);
        } else {
            console.log("NoOpMigrator deployed to:", noOpMigrator);
        }
    }

    function _verifyNoOpMigratorDeployment(address addr, address airlock) internal view {
        require(address(NoOpMigrator(addr).airlock()) == airlock, "NoOpMigrator airlock mismatch");
    }
}

contract DeployNoOpMigratorScript is DeployNoOpMigrator {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address noOpMigrator) {
        return _deployNoOpMigrator(_deployContext());
    }
}

contract DeployNoOpMigratorScriptEthereum is DeployNoOpMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployNoOpMigratorScriptMonad is DeployNoOpMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployNoOpMigratorScriptBase is DeployNoOpMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployNoOpMigratorScriptRobinhood is DeployNoOpMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployNoOpMigratorScriptBaseSepolia is DeployNoOpMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
