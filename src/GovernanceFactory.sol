// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { Governance, IVotes } from "src/Governance.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

/// @notice Thrown when the caller is not the Airlock contract
error OnlyAirlock();

/// @custom:security-contact security@whetstone.cc
contract GovernanceFactory is IGovernanceFactory {
    TimelockFactory public immutable timelockFactory;
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
        timelockFactory = new TimelockFactory();
    }

    function create(address asset, bytes calldata data) external returns (address, address) {
        require(msg.sender == airlock, OnlyAirlock());

        (string memory name) = abi.decode(data, (string));

        TimelockController timelockController = timelockFactory.create();
        address governance =
            address(new Governance(string.concat(name, " Governance"), IVotes(asset), timelockController));
        timelockController.grantRole(keccak256("PROPOSER_ROLE"), governance);
        timelockController.grantRole(keccak256("CANCELLER_ROLE"), governance);
        timelockController.grantRole(keccak256("EXECUTOR_ROLE"), address(0));

        timelockController.renounceRole(bytes32(0x00), address(this));

        return (governance, address(timelockController));
    }
}

contract TimelockFactory {
    function create() external returns (TimelockController) {
        return new TimelockController(1 days, new address[](0), new address[](0), msg.sender);
    }
}
