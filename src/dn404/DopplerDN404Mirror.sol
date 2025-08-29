// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404Mirror } from "lib/dn404/src/DN404Mirror.sol";

/// @title DopplerDN404Mirror
/// @notice Thin wrapper around DN404Mirror for Doppler DN404 deployments.
contract DopplerDN404Mirror is DN404Mirror {
    constructor(
        address deployer
    ) DN404Mirror(deployer) { }
}
