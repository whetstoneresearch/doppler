// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { SwapRestrictorDopplerHook } from "src/dopplerHooks/SwapRestrictorDopplerHook.sol";

abstract contract DeploySwapRestrictorDopplerHook is DeployBase {
    function _deploySwapRestrictorDopplerHook(DeployContext memory context)
        internal
        returns (address swapRestrictorDopplerHook)
    {
        address dopplerHookInitializer = context.config.get(context.chainId, "doppler_hook_initializer").toAddress();
        return _deploySwapRestrictorDopplerHook(context, dopplerHookInitializer);
    }

    function _deploySwapRestrictorDopplerHook(
        DeployContext memory context,
        address dopplerHookInitializer
    ) internal returns (address swapRestrictorDopplerHook) {
        bytes memory initCode = abi.encodePacked(
            type(SwapRestrictorDopplerHook).creationCode, abi.encode(dopplerHookInitializer)
        );

        bool alreadyDeployed;
        (swapRestrictorDopplerHook, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(SwapRestrictorDopplerHook).name,
            SWAP_RESTRICTOR_DOPPLER_HOOK_VERSION,
            initCode
        );

        _verifySwapRestrictorDopplerHookDeployment(swapRestrictorDopplerHook, dopplerHookInitializer);
        _setConfigAddress(context, "swap_restrictor_doppler_hook", swapRestrictorDopplerHook);

        if (alreadyDeployed) {
            console.log("SwapRestrictorDopplerHook already deployed to:", swapRestrictorDopplerHook);
        } else {
            console.log("SwapRestrictorDopplerHook deployed to:", swapRestrictorDopplerHook);
        }
    }

    function _verifySwapRestrictorDopplerHookDeployment(address addr, address initializer) internal view {
        require(SwapRestrictorDopplerHook(addr).INITIALIZER() == initializer, "SwapRestrictor initializer mismatch");
    }
}

contract DeploySwapRestrictorDopplerHookScript is DeploySwapRestrictorDopplerHook {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address swapRestrictorDopplerHook) {
        return _deploySwapRestrictorDopplerHook(_deployContext());
    }
}

contract DeploySwapRestrictorDopplerHookScriptEthereum is DeploySwapRestrictorDopplerHookScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeploySwapRestrictorDopplerHookScriptMonad is DeploySwapRestrictorDopplerHookScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeploySwapRestrictorDopplerHookScriptBase is DeploySwapRestrictorDopplerHookScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeploySwapRestrictorDopplerHookScriptBaseSepolia is DeploySwapRestrictorDopplerHookScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
