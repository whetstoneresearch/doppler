// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";

abstract contract DeployDopplerERC20V1Factory is DeployBase {
    function _deployDopplerERC20V1Factory(DeployContext memory context)
        internal
        returns (address dopplerERC20V1Factory)
    {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployDopplerERC20V1Factory(context, airlock);
    }

    function _deployDopplerERC20V1Factory(
        DeployContext memory context,
        address airlock
    ) internal returns (address dopplerERC20V1Factory) {
        bytes memory initCode = abi.encodePacked(type(DopplerERC20V1Factory).creationCode, abi.encode(airlock));

        bool alreadyDeployed;
        (dopplerERC20V1Factory, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(DopplerERC20V1Factory).name,
            DOPPLER_ERC20_V1_FACTORY_VERSION,
            initCode
        );

        address implementation = _verifyDopplerERC20V1FactoryDeployment(dopplerERC20V1Factory, airlock);
        _setConfigAddress(context, "doppler_erc20_v1_factory", dopplerERC20V1Factory);
        _setConfigAddress(context, "doppler_erc20_v1_implementation", implementation);

        if (alreadyDeployed) {
            console.log("DopplerERC20V1Factory already deployed to:", dopplerERC20V1Factory);
        } else {
            console.log("DopplerERC20V1Factory deployed to:", dopplerERC20V1Factory);
        }
        console.log("DopplerERC20V1 implementation deployed to:", implementation);
    }

    function _verifyDopplerERC20V1FactoryDeployment(
        address addr,
        address airlock
    ) internal view returns (address implementation) {
        DopplerERC20V1Factory factory = DopplerERC20V1Factory(addr);
        require(address(factory.airlock()) == airlock, "DopplerERC20V1Factory airlock mismatch");

        implementation = factory.IMPLEMENTATION();
        require(
            implementation != address(0) && implementation.code.length != 0, "Invalid DopplerERC20V1 implementation"
        );
    }
}

contract DeployDopplerERC20V1FactoryScript is DeployDopplerERC20V1Factory {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address dopplerERC20V1Factory) {
        return _deployDopplerERC20V1Factory(_deployContext());
    }
}

contract DeployDopplerERC20V1FactoryScriptEthereum is DeployDopplerERC20V1FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDopplerERC20V1FactoryScriptMonad is DeployDopplerERC20V1FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDopplerERC20V1FactoryScriptBase is DeployDopplerERC20V1FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDopplerERC20V1FactoryScriptBaseSepolia is DeployDopplerERC20V1FactoryScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
