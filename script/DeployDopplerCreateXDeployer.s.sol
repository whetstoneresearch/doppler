// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerCreateXDeployer } from "src/DopplerCreateXDeployer.sol";

contract DeployDopplerCreateXDeployerScript is DeployBase {
    string internal constant DOPPLER_CREATEX_DEPLOYER_ARTIFACT =
        "src/DopplerCreateXDeployer.sol:DopplerCreateXDeployer";

    // Set in contract wrappers
    bytes32 public salt;
    address public expectedAddress;

    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function initCodeHash() public view returns (bytes32) {
        return initCodeHash(config.get("deployer_owner").toAddress());
    }

    function initCodeHash(address deployerOwner) public view returns (bytes32) {
        return keccak256(_initCode(deployerOwner));
    }

    function run() public {
        require(salt != bytes32(0), "Salt is not configured");
        require(expectedAddress != address(0), "Expected address is not configured");

        address deployerOwner = config.get("deployer_owner").toAddress();
        bytes memory initCode = _initCode(deployerOwner);

        (address deployer, bool alreadyDeployed) = _deployOrUseExistingCreateXCreate2(salt, expectedAddress, initCode);

        _verifyExistingDeployment(deployer, deployerOwner);
        _setConfigAddress(PROTOCOL_DEPLOYER_KEY, deployer);

        if (alreadyDeployed) {
            console.log("Protocol deployer already deployed to:", deployer);
        } else {
            console.log("Protocol deployer deployed to:", deployer);
        }
    }

    function _initCode(address deployerOwner) internal view returns (bytes memory) {
        return abi.encodePacked(vm.getCode(DOPPLER_CREATEX_DEPLOYER_ARTIFACT), abi.encode(deployerOwner));
    }

    function _verifyExistingDeployment(address addr, address owner) internal view {
        DopplerCreateXDeployer deployer = DopplerCreateXDeployer(payable(addr));

        // Verify owner
        if (owner != address(0)) require(deployer.owner() == owner, "Deployer owner mismatch");

        // Verify interface
        bytes32 _salt = deployer.generateSalt("DopplerCreateXDeployer", 1);
        bytes32 guardedSalt = deployer.computeGuardedSalt(_salt);
        deployer.computeCreate2Address(guardedSalt, initCodeHash(owner));
        deployer.computeCreate3Address(guardedSalt);
    }
}

contract DeployDopplerCreateXDeployerScriptEthereum is DeployDopplerCreateXDeployerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
        salt = hex"b3a2b7b26a65dd0292755b000000000000000000000000000000000000000000";
        expectedAddress = 0x103004E50Bed65DFBa30dD9c264B6BdF5e529B83;
    }
}

contract DeployDopplerCreateXDeployerScriptMonad is DeployDopplerCreateXDeployerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
        salt = hex"b3a2b7b26a65dd0292755b000000000000000000000000000000000000000000";
        expectedAddress = 0x103004E50Bed65DFBa30dD9c264B6BdF5e529B83;
    }
}

contract DeployDopplerCreateXDeployerScriptBase is DeployDopplerCreateXDeployerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
        salt = hex"b3a2b7b26a65dd0292755b000000000000000000000000000000000000000000";
        expectedAddress = 0x103004E50Bed65DFBa30dD9c264B6BdF5e529B83;
    }
}

contract DeployDopplerCreateXDeployerScriptRobinhood is DeployDopplerCreateXDeployerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
        salt = hex"b3a2b7b26a65dd0292755b000000000000000000000000000000000000000000";
        expectedAddress = 0x103004E50Bed65DFBa30dD9c264B6BdF5e529B83;
    }
}

contract DeployDopplerCreateXDeployerScriptBaseSepolia is DeployDopplerCreateXDeployerScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
        salt = hex"b3a2b7b26a65dd0292755b000000000000000000000000000000000000000000";
        expectedAddress = 0x0000000000f13Ab5b685F03A412A26719aB6bE60;
    }
}
