// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { Bundler } from "src/Bundler.sol";

abstract contract DeployBundler is DeployBase {
    function _deployBundler(DeployContext memory context) internal returns (address bundler) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployBundler(context, airlock);
    }

    function _deployBundler(DeployContext memory context, address airlock) internal returns (address bundler) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        bytes memory initCode = abi.encodePacked(type(Bundler).creationCode, abi.encode(airlock, poolManager));

        bool alreadyDeployed;
        (bundler, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(Bundler).name, BUNDLER_VERSION, initCode
        );

        _verifyBundlerDeployment(bundler, airlock, poolManager);
        _setConfigAddress(context, "bundler", bundler);

        if (alreadyDeployed) {
            console.log("Bundler already deployed to:", bundler);
        } else {
            console.log("Bundler deployed to:", bundler);
        }
    }

    function _verifyBundlerDeployment(address addr, address airlock, address poolManager) internal view {
        Bundler bundler = Bundler(addr);
        require(address(bundler.airlock()) == airlock, "Bundler airlock mismatch");
        require(address(bundler.poolManager()) == poolManager, "Bundler pool manager mismatch");
    }
}

contract DeployBundlerScript is DeployBundler {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address bundler) {
        return _deployBundler(_deployContext());
    }
}

contract DeployBundlerScriptEthereum is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployBundlerScriptMonad is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployBundlerScriptRobinhood is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployBundlerScriptBase is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployBundlerScriptArbitrum is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ARBITRUM_MAINNET, false);
    }
}

contract DeployBundlerScriptBaseSepolia is DeployBundlerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
