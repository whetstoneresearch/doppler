// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

uint160 constant DOPPLER_HOOK_INITIALIZER_FLAGS = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
);

abstract contract DeployDopplerHookInitializer is DeployBase {
    function _deployDopplerHookInitializer(DeployContext memory context)
        internal
        returns (address dopplerHookInitializer)
    {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployDopplerHookInitializer(context, airlock);
    }

    function _deployDopplerHookInitializer(
        DeployContext memory context,
        address airlock
    ) internal returns (address dopplerHookInitializer) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        bytes memory initCode =
            abi.encodePacked(type(DopplerHookInitializer).creationCode, abi.encode(airlock, poolManager));
        (bytes32 salt, address expected) = _mineDopplerHookInitializerSalt(context, airlock, poolManager);

        bool alreadyDeployed;
        (dopplerHookInitializer, alreadyDeployed) = _deployOrUseExistingCreate3(context, salt, expected, initCode);

        _verifyDopplerHookInitializerDeployment(dopplerHookInitializer, airlock, poolManager);
        _setConfigAddress(context, "doppler_hook_initializer", dopplerHookInitializer);

        if (alreadyDeployed) {
            console.log("DopplerHookInitializer already deployed to:", dopplerHookInitializer);
        } else {
            console.log("DopplerHookInitializer deployed to:", dopplerHookInitializer);
        }
    }

    function _mineDopplerHookInitializerSalt(
        DeployContext memory context,
        address airlock,
        address poolManager
    ) internal view returns (bytes32 salt, address expected) {
        bytes32 baseSalt = context.protocolDeployer
            .generateSalt(type(DopplerHookInitializer).name, MULTICURVE_INITIALIZER_VERSION);

        for (uint88 seed; seed < type(uint88).max; seed++) {
            salt = bytes32(uint256(baseSalt) + seed);
            expected = _computeProtocolCreate3Address(context.protocolDeployer, salt);

            if (
                uint160(expected) & Hooks.ALL_HOOK_MASK == DOPPLER_HOOK_INITIALIZER_FLAGS
                    && (expected.code.length == 0
                        || _isDopplerHookInitializerDeployment(expected, airlock, poolManager))
            ) {
                return (salt, expected);
            }
        }

        revert("DopplerHookInitializer salt not found");
    }

    function _isDopplerHookInitializerDeployment(
        address addr,
        address airlock,
        address poolManager
    ) internal view returns (bool) {
        (bool airlockSuccess, bytes memory airlockResult) =
            addr.staticcall(abi.encodeWithSelector(bytes4(keccak256("airlock()"))));
        if (!airlockSuccess || airlockResult.length != 32 || abi.decode(airlockResult, (address)) != airlock) {
            return false;
        }

        (bool poolManagerSuccess, bytes memory poolManagerResult) =
            addr.staticcall(abi.encodeWithSelector(bytes4(keccak256("poolManager()"))));
        return
            poolManagerSuccess && poolManagerResult.length == 32
                && abi.decode(poolManagerResult, (address)) == poolManager;
    }

    function _verifyDopplerHookInitializerDeployment(address addr, address airlock, address poolManager) internal view {
        DopplerHookInitializer initializer = DopplerHookInitializer(payable(addr));
        require(address(initializer.airlock()) == airlock, "DopplerHookInitializer airlock mismatch");
        require(address(initializer.poolManager()) == poolManager, "DopplerHookInitializer pool manager mismatch");
    }
}

contract DeployDopplerHookInitializerScript is DeployDopplerHookInitializer {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address dopplerHookInitializer) {
        return _deployDopplerHookInitializer(_deployContext());
    }
}

contract DeployDopplerHookInitializerScriptEthereum is DeployDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDopplerHookInitializerScriptMonad is DeployDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDopplerHookInitializerScriptBase is DeployDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDopplerHookInitializerScriptRobinhood is DeployDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployDopplerHookInitializerScriptBaseSepolia is DeployDopplerHookInitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
