// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LaunchpadGovernanceFactory } from "src/governance/LaunchpadGovernanceFactory.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

contract LaunchpadGovernanceFactoryTest is Test {
    LaunchpadGovernanceFactory public factory;

    function setUp() public {
        factory = new LaunchpadGovernanceFactory();
    }

    function test_create_ReturnsDEADGovernanceAndValidMultisig() public view {
        address asset = address(0x1234); // dummy asset address
        address multisig = address(0x5678); // dummy multisig address

        // Call create with dummy parameters
        (address governance, address timelockController) = factory.create(asset, abi.encode(multisig));

        // Assert governance address is DEAD_ADDRESS and timelock controller is the dummy multisig address
        assertEq(governance, DEAD_ADDRESS, "Governance address should be DEAD_ADDRESS");
        assertEq(timelockController, multisig, "Timelock controller address should be dummy multisig address");
    }
}
