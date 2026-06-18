// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";

abstract contract DeployRehypeDopplerHookMigrator is DeployBase {
    function _deployRehypeDopplerHookMigrator(DeployContext memory context)
        internal
        returns (address rehypeDopplerHookMigrator)
    {
        address migrator = context.config.get(context.chainId, "doppler_hook_migrator").toAddress();
        return _deployRehypeDopplerHookMigrator(context, migrator);
    }

    function _deployRehypeDopplerHookMigrator(
        DeployContext memory context,
        address migrator
    ) internal returns (address rehypeDopplerHookMigrator) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        bytes memory initCode =
            abi.encodePacked(type(RehypeDopplerHookMigrator).creationCode, abi.encode(migrator, poolManager));

        bool alreadyDeployed;
        (rehypeDopplerHookMigrator, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(RehypeDopplerHookMigrator).name,
            REHYPE_DOPPLER_HOOK_MIGRATOR_VERSION,
            initCode
        );

        address quoter = _verifyRehypeDopplerHookMigratorDeployment(rehypeDopplerHookMigrator, migrator, poolManager);
        _setConfigAddress(context, "rehype_doppler_hook_migrator", rehypeDopplerHookMigrator);
        _setConfigAddress(context, "quoter", quoter);

        if (alreadyDeployed) {
            console.log("RehypeDopplerHookMigrator already deployed to:", rehypeDopplerHookMigrator);
        } else {
            console.log("RehypeDopplerHookMigrator deployed to:", rehypeDopplerHookMigrator);
        }
        console.log("RehypeDopplerHookMigrator quoter deployed to:", quoter);
    }

    function _verifyRehypeDopplerHookMigratorDeployment(
        address addr,
        address migrator,
        address poolManager
    ) internal view returns (address quoter) {
        RehypeDopplerHookMigrator hook = RehypeDopplerHookMigrator(payable(addr));
        require(address(hook.MIGRATOR()) == migrator, "RehypeDopplerHookMigrator migrator mismatch");
        require(address(hook.poolManager()) == poolManager, "RehypeDopplerHookMigrator pool manager mismatch");

        quoter = address(hook.quoter());
        require(quoter != address(0) && quoter.code.length != 0, "RehypeDopplerHookMigrator quoter missing");
    }
}

contract DeployRehypeDopplerHookMigratorScript is DeployRehypeDopplerHookMigrator {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address rehypeDopplerHookMigrator) {
        return _deployRehypeDopplerHookMigrator(_deployContext());
    }
}

contract DeployRehypeDopplerHookMigratorScriptEthereum is DeployRehypeDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookMigratorScriptMonad is DeployRehypeDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookMigratorScriptBase is DeployRehypeDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookMigratorScriptBaseSepolia is DeployRehypeDopplerHookMigratorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
