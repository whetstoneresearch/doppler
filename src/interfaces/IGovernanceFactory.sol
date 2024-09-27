// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TimelockController} from "openzeppelin/governance/TimelockController.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";

interface IGovernanceFactory {
    function create(address token, bytes memory governanceData)
        external
        returns (address governance, TimelockController timelockController);
}
