// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";

contract NoOpGovernanceFactoryTest is Test {
    NoOpGovernanceFactory public factory;

    function setUp() public {
        factory = new NoOpGovernanceFactory();
    }

    function test_create_ReturnsDEADAddress() public {
        // Call create with dummy parameters
        (address governance, address timelockController) =
            factory.create(
                address(0x1234), // dummy asset address
                "" // empty governance data
            );

        // Assert both addresses equal DEAD_ADDRESS
        assertEq(governance, factory.DEAD_ADDRESS(), "Governance address should be DEAD_ADDRESS");
        assertEq(timelockController, factory.DEAD_ADDRESS(), "Timelock controller address should be DEAD_ADDRESS");

        // Additional check to ensure DEAD_ADDRESS is 0xdead
        assertEq(factory.DEAD_ADDRESS(), address(0xdead), "DEAD_ADDRESS should be 0xdead");
    }
}
