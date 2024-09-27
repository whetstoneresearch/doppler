/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Governance, IVotes} from "src/Governance.sol";
import {TimelockController} from "openzeppelin/governance/TimelockController.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";

contract GovernanceFactory is IGovernanceFactory {
    function create(string memory name, address token, bytes memory)
        external
        returns (address governance, TimelockController timelockController)
    {
        timelockController = new TimelockController(2 days, new address[](0), new address[](0), address(0));
        governance = address(new Governance(name, IVotes(token), TimelockController(timelockController)));
    }
}
