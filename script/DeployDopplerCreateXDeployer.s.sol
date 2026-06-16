// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { DopplerCreateXDeployer } from "src/DopplerCreateXDeployer.sol";

contract DeployDopplerCreateXDeployerScript is DeployBase {
    bytes32 public salt; // TODO: Mine and set a salt
    address public expectedAddress; // TODO: Compute expected address from salt and init code hash

    function setUp() public {
        _loadConfigForCurrentChain();
    }

    function run() public {
        require(salt != bytes32(0), "Salt is not configured");
        require(expectedAddress != address(0), "Expected address is not configured");

        address deployerOwner = config.get("deployer_owner").toAddress();
        bytes memory initCode = abi.encodePacked(type(DopplerCreateXDeployer).creationCode, abi.encode(deployerOwner));

        (address deployer, bool alreadyDeployed) = _deployOrUseExistingCreateXCreate3(salt, expectedAddress, initCode);

        _verifyExistingDeployment(deployer, deployerOwner);
        _setConfigAddress(PROTOCOL_DEPLOYER_KEY, deployer);

        if (alreadyDeployed) {
            console.log("Protocol deployer already deployed to:", deployer);
        } else {
            console.log("Protocol deployer deployed to:", deployer);
        }
    }

    function _verifyExistingDeployment(address addr, address owner) internal view {
        DopplerCreateXDeployer deployer = DopplerCreateXDeployer(payable(addr));

        // Verify owner
        if (owner != address(0)) require(deployer.owner() == owner, "Deployer owner mismatch");

        // Verify interface
        bytes32 _salt = deployer.generateSalt("DopplerCreateXDeployer", 1);
        bytes32 guardedSalt = deployer.computeGuardedSalt(_salt);
        deployer.computeCreate2Address(
            guardedSalt, keccak256(abi.encodePacked(type(DopplerCreateXDeployer).creationCode, abi.encode(owner)))
        );
        deployer.computeCreate3Address(guardedSalt);
    }
}
