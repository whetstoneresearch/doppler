// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

interface IGovernanceFactory {
    function create(
        string memory name,
        address token,
        bytes memory governanceData
    ) external returns (address governance, address timelockController);
}
