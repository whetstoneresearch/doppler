// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";

abstract contract DeployUniswapV4Initializer is DeployBase {
    function _deployUniswapV4Initializer(DeployContext memory context) internal returns (address uniswapV4Initializer) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployUniswapV4Initializer(context, airlock);
    }

    function _deployUniswapV4Initializer(
        DeployContext memory context,
        address airlock
    ) internal returns (address uniswapV4Initializer) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();

        address dopplerDeployer = _deployDopplerDeployer(context, poolManager);
        bytes memory initCode = abi.encodePacked(
            type(UniswapV4Initializer).creationCode, abi.encode(airlock, poolManager, dopplerDeployer)
        );

        bool alreadyDeployed;
        (uniswapV4Initializer, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(UniswapV4Initializer).name, DYNAMIC_INITIALIZER_VERSION, initCode
        );

        _verifyUniswapV4InitializerDeployment(uniswapV4Initializer, airlock, poolManager, dopplerDeployer);
        _setConfigAddress(context, "uniswap_v4_initializer", uniswapV4Initializer);

        if (alreadyDeployed) {
            console.log("UniswapV4Initializer already deployed to:", uniswapV4Initializer);
        } else {
            console.log("UniswapV4Initializer deployed to:", uniswapV4Initializer);
        }
    }

    function _deployDopplerDeployer(
        DeployContext memory context,
        address poolManager
    ) internal returns (address dopplerDeployer) {
        bytes memory initCode = abi.encodePacked(type(DopplerDeployer).creationCode, abi.encode(poolManager));

        bool alreadyDeployed;
        (dopplerDeployer, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(DopplerDeployer).name, DYNAMIC_INITIALIZER_VERSION, initCode
        );

        _verifyDopplerDeployerDeployment(dopplerDeployer, poolManager);
        _setConfigAddress(context, "doppler_deployer", dopplerDeployer);

        if (alreadyDeployed) {
            console.log("DopplerDeployer already deployed to:", dopplerDeployer);
        } else {
            console.log("DopplerDeployer deployed to:", dopplerDeployer);
        }
    }

    function _verifyDopplerDeployerDeployment(address addr, address poolManager) internal view {
        require(address(DopplerDeployer(addr).poolManager()) == poolManager, "DopplerDeployer pool manager mismatch");
    }

    function _verifyUniswapV4InitializerDeployment(
        address addr,
        address airlock,
        address poolManager,
        address dopplerDeployer
    ) internal view {
        UniswapV4Initializer initializer = UniswapV4Initializer(addr);
        require(address(initializer.airlock()) == airlock, "UniswapV4Initializer airlock mismatch");
        require(address(initializer.poolManager()) == poolManager, "UniswapV4Initializer pool manager mismatch");
        require(address(initializer.deployer()) == dopplerDeployer, "UniswapV4Initializer deployer mismatch");
    }
}

contract DeployUniswapV4InitializerScript is DeployUniswapV4Initializer {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address uniswapV4Initializer) {
        return _deployUniswapV4Initializer(_deployContext());
    }
}

contract DeployUniswapV4InitializerScriptEthereum is DeployUniswapV4InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployUniswapV4InitializerScriptMonad is DeployUniswapV4InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployUniswapV4InitializerScriptBase is DeployUniswapV4InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployUniswapV4InitializerScriptRobinhood is DeployUniswapV4InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployUniswapV4InitializerScriptBaseSepolia is DeployUniswapV4InitializerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
