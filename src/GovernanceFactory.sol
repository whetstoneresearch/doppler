/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Governance, IVotes } from "src/Governance.sol";
import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

error NotAirlock();

contract GovernanceFactory is IGovernanceFactory {
    TimelockFactory public immutable timelockFactory;
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
        timelockFactory = new TimelockFactory();
    }

    function create(string memory name, address token, bytes memory) external returns (address, address) {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        TimelockController timelockController = timelockFactory.create();
        address governance =
            address(new Governance(string.concat(name, " Governance"), IVotes(token), timelockController));
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
