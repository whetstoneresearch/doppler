// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";

abstract contract DeployRehypeDopplerHookInitializer is DeployBase {
    function _deployRehypeDopplerHookInitializer(DeployContext memory context)
        internal
        returns (address rehypeDopplerHookInitializer)
    {
        address dopplerHookInitializer = context.config.get(context.chainId, "doppler_hook_initializer").toAddress();
        return _deployRehypeDopplerHookInitializer(context, dopplerHookInitializer);
    }

    function _deployRehypeDopplerHookInitializer(
        DeployContext memory context,
        address dopplerHookInitializer
    ) internal returns (address rehypeDopplerHookInitializer) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        bytes memory initCode = abi.encodePacked(
            type(RehypeDopplerHookInitializer).creationCode, abi.encode(dopplerHookInitializer, poolManager)
        );

        bool alreadyDeployed;
        (rehypeDopplerHookInitializer, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(RehypeDopplerHookInitializer).name,
            REHYPE_DOPPLER_HOOK_INITIALIZER_VERSION,
            initCode
        );

        address quoter = _verifyRehypeDopplerHookInitializerDeployment(
            rehypeDopplerHookInitializer, dopplerHookInitializer, poolManager
        );
        _setConfigAddress(context, "rehype_doppler_hook_initializer", rehypeDopplerHookInitializer);
        _setConfigAddress(context, "quoter", quoter);

        if (alreadyDeployed) {
            console.log("RehypeDopplerHookInitializer already deployed to:", rehypeDopplerHookInitializer);
        } else {
            console.log("RehypeDopplerHookInitializer deployed to:", rehypeDopplerHookInitializer);
        }
        console.log("RehypeDopplerHookInitializer quoter deployed to:", quoter);
    }

    function _verifyRehypeDopplerHookInitializerDeployment(
        address addr,
        address dopplerHookInitializer,
        address poolManager
    ) internal view returns (address quoter) {
        RehypeDopplerHookInitializer hook = RehypeDopplerHookInitializer(payable(addr));
        require(hook.INITIALIZER() == dopplerHookInitializer, "RehypeDopplerHookInitializer initializer mismatch");
        require(address(hook.poolManager()) == poolManager, "RehypeDopplerHookInitializer pool manager mismatch");

        quoter = address(hook.quoter());
        require(quoter != address(0) && quoter.code.length != 0, "RehypeDopplerHookInitializer quoter missing");
    }
}

contract DeployRehypeDopplerHookInitializerScript is DeployRehypeDopplerHookInitializer {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address rehypeDopplerHookInitializer) {
        return _deployRehypeDopplerHookInitializer(_deployContext());
    }
}

contract DeployRehypeDopplerHookInitializerScriptEthereum is DeployRehypeDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookInitializerScriptMonad is DeployRehypeDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookInitializerScriptBase is DeployRehypeDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookInitializerScriptRobinhood is DeployRehypeDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployRehypeDopplerHookInitializerScriptBaseSepolia is DeployRehypeDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
