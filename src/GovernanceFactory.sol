// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { Governance, IVotes } from "./Governance.sol";
import { IGovernanceFactory } from "./interfaces/IGovernanceFactory.sol";
import { ImmutableAirlock } from "./base/ImmutableAirlock.sol";

/// @custom:security-contact security@whetstone.cc
contract GovernanceFactory is IGovernanceFactory, ImmutableAirlock {
    TimelockFactory public immutable timelockFactory;

    constructor(
        address airlock_
    ) ImmutableAirlock(airlock_) {
        timelockFactory = new TimelockFactory();
    }

    function create(address asset, bytes calldata data) external onlyAirlock returns (address, address) {
        (string memory name, uint48 initialVotingDelay, uint32 initialVotingPeriod, uint256 initialProposalThreshold) =
            abi.decode(data, (string, uint48, uint32, uint256));

        TimelockController timelockController = timelockFactory.create();
        address governance = address(
            new Governance(
                string.concat(name, " Governance"),
                IVotes(asset),
                timelockController,
                initialVotingDelay,
                initialVotingPeriod,
                initialProposalThreshold
            )
        );
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
