// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IGovernanceFactory {
    function create(
        address asset,
        bytes calldata governanceData
    ) external returns (address governance, address timelockController);
}
