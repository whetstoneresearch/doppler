// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { LockableUniswapV3Initializer } from "src/initializers/LockableUniswapV3Initializer.sol";

abstract contract DeployLockableUniswapV3Initializer is DeployBase {
    function _deployLockableUniswapV3Initializer(DeployContext memory context)
        internal
        returns (address lockableUniswapV3Initializer)
    {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployLockableUniswapV3Initializer(context, airlock);
    }

    function _deployLockableUniswapV3Initializer(
        DeployContext memory context,
        address airlock
    ) internal returns (address lockableUniswapV3Initializer) {
        address uniswapV3Factory = context.config.get(context.chainId, "uniswap_v3_factory").toAddress();
        bytes memory initCode =
            abi.encodePacked(type(LockableUniswapV3Initializer).creationCode, abi.encode(airlock, uniswapV3Factory));

        bool alreadyDeployed;
        (lockableUniswapV3Initializer, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(LockableUniswapV3Initializer).name,
            STATIC_INITIALIZER_VERSION,
            initCode
        );

        _verifyLockableUniswapV3InitializerDeployment(lockableUniswapV3Initializer, airlock, uniswapV3Factory);
        _setConfigAddress(context, "lockable_uniswap_v3_initializer", lockableUniswapV3Initializer);

        if (alreadyDeployed) {
            console.log("LockableUniswapV3Initializer already deployed to:", lockableUniswapV3Initializer);
        } else {
            console.log("LockableUniswapV3Initializer deployed to:", lockableUniswapV3Initializer);
        }
    }

    function _verifyLockableUniswapV3InitializerDeployment(
        address addr,
        address airlock,
        address uniswapV3Factory
    ) internal view {
        LockableUniswapV3Initializer initializer = LockableUniswapV3Initializer(payable(addr));
        require(address(initializer.airlock()) == airlock, "LockableUniswapV3Initializer airlock mismatch");
        require(address(initializer.factory()) == uniswapV3Factory, "LockableUniswapV3Initializer factory mismatch");
    }
}

contract DeployLockableUniswapV3InitializerScript is DeployLockableUniswapV3Initializer {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address lockableUniswapV3Initializer) {
        return _deployLockableUniswapV3Initializer(_deployContext());
    }
}

contract DeployLockableUniswapV3InitializerScriptEthereum is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployLockableUniswapV3InitializerScriptMonad is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployLockableUniswapV3InitializerScriptBase is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployLockableUniswapV3InitializerScriptBaseSepolia is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
