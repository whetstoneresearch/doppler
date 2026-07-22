// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DN404Factory } from "src/tokens/DN404Factory.sol";

abstract contract DeployDN404Factory is DeployBase {
    function _deployDN404Factory(DeployContext memory context) internal returns (address factory) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployDN404Factory(context, airlock);
    }

    function _deployDN404Factory(DeployContext memory context, address airlock) internal returns (address factory) {
        bytes memory initCode = abi.encodePacked(type(DN404Factory).creationCode, abi.encode(airlock));

        bool alreadyDeployed;
        (factory, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(DN404Factory).name, DOPPLER_DN404_FACTORY_VERSION, initCode
        );

        _verifyDN404FactoryDeployment(factory, airlock);
        _setConfigAddress(context, "dn404_factory", factory);

        if (alreadyDeployed) {
            console.log("DN404Factory already deployed to:", factory);
        } else {
            console.log("DN404Factory deployed to:", factory);
        }
    }

    function _verifyDN404FactoryDeployment(address addr, address airlock) internal view {
        require(address(DN404Factory(addr).airlock()) == airlock, "DN404Factory airlock mismatch");
    }
}

contract DeployDN404FactoryScript is DeployDN404Factory {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address factory) {
        return _deployDN404Factory(_deployContext());
    }
}

contract DeployDN404FactoryScriptEthereum is DeployDN404FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDN404FactoryScriptMonad is DeployDN404FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDN404FactoryScriptBase is DeployDN404FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDN404FactoryScriptRobinhood is DeployDN404FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployDN404FactoryScriptBaseSepolia is DeployDN404FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
