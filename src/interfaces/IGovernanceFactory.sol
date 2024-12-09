// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

interface IGovernanceFactory {
    function create(
        address asset,
        bytes memory governanceData
    ) external returns (address governance, address timelockController);
}
