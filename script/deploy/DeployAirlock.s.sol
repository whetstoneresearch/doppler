// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { Airlock } from "src/Airlock.sol";

abstract contract DeployAirlock is DeployBase {
    bytes32 public salt; // Only set if you want to use a specific salt
    address public expectedAddress; // Only set if you've configured a custom salt

    function _deployAirlock(DeployContext memory context) internal returns (address airlock) {
        address multisig = context.config.get(context.chainId, "airlock_multisig").toAddress();
        return _deployAirlock(context, multisig);
    }

    function _deployAirlock(DeployContext memory context, address multisig) internal returns (address airlock) {
        bytes memory initCode = abi.encodePacked(type(Airlock).creationCode, abi.encode(multisig));

        bool alreadyDeployed;
        (airlock, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, salt, expectedAddress, type(Airlock).name, AIRLOCK_VERSION, initCode
        );

        _verifyExistingDeployment(airlock, multisig);
        _setConfigAddress(context, "airlock", airlock);

        if (alreadyDeployed) {
            console.log("Airlock already deployed to:", airlock);
        } else {
            console.log("Airlock deployed to:", airlock);
        }
    }

    function _verifyExistingDeployment(address addr, address owner) internal view {
        Airlock airlock = Airlock(payable(addr));

        // Verify owner
        if (owner != address(0)) require(airlock.owner() == owner, "Airlock owner mismatch");

        // Verify interface
        airlock.getModuleState(address(0));
        airlock.getAssetData(address(0));
        airlock.getProtocolFees(address(0));
        airlock.getIntegratorFees(address(0), address(0));
    }
}

contract DeployAirlockScript is DeployAirlock {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address airlock) {
        return _deployAirlock(_deployContext());
    }
}

contract DeployAirlockScriptEthereum is DeployAirlockScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployAirlockScriptMonad is DeployAirlockScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployAirlockScriptBase is DeployAirlockScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployAirlockScriptBaseSepolia is DeployAirlockScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
