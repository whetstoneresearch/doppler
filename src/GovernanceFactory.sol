/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Governance, IVotes } from "src/Governance.sol";
import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

contract GovernanceFactory is IGovernanceFactory {
    function create(string memory name, address token, bytes memory) external returns (address, address) {
        TimelockController timelockController =
            new TimelockController(1 days, new address[](0), new address[](0), address(this));
        address governance = address(
            new Governance(string.concat(name, " Governance"), IVotes(token), TimelockController(timelockController))
        );
        timelockController.grantRole(keccak256("PROPOSER_ROLE"), governance);
        timelockController.grantRole(keccak256("CANCELLER_ROLE"), governance);
        timelockController.grantRole(keccak256("EXECUTOR_ROLE"), address(0));

        timelockController.renounceRole(bytes32(0x00), address(this));

        return (governance, address(timelockController));
    }
}
