// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";

abstract contract DeployTopUpDistributor is DeployBase {
    function _deployTopUpDistributor(DeployContext memory context) internal returns (address topUpDistributor) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        return _deployTopUpDistributor(context, airlock);
    }

    function _deployTopUpDistributor(
        DeployContext memory context,
        address airlock
    ) internal returns (address topUpDistributor) {
        bytes memory initCode = abi.encodePacked(type(TopUpDistributor).creationCode, abi.encode(airlock));

        bool alreadyDeployed;
        (topUpDistributor, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(TopUpDistributor).name, TOP_UP_DISTRIBUTOR_VERSION, initCode
        );

        _verifyTopUpDistributorDeployment(topUpDistributor, airlock);
        _setConfigAddress(context, "top_up_distributor", topUpDistributor);

        if (alreadyDeployed) {
            console.log("TopUpDistributor already deployed to:", topUpDistributor);
        } else {
            console.log("TopUpDistributor deployed to:", topUpDistributor);
        }
    }

    function _verifyTopUpDistributorDeployment(address addr, address airlock) internal view {
        require(address(TopUpDistributor(payable(addr)).AIRLOCK()) == airlock, "TopUpDistributor airlock mismatch");
    }
}

contract DeployTopUpDistributorScript is DeployTopUpDistributor {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address topUpDistributor) {
        return _deployTopUpDistributor(_deployContext());
    }
}

contract DeployTopUpDistributorScriptEthereum is DeployTopUpDistributorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployTopUpDistributorScriptMonad is DeployTopUpDistributorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployTopUpDistributorScriptBase is DeployTopUpDistributorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployTopUpDistributorScriptBaseSepolia is DeployTopUpDistributorScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
