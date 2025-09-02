// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404Mirror } from "lib/dn404/src/DN404Mirror.sol";
import { DopplerDN404 } from "src/dn404/DopplerDN404.sol";

/// @title DopplerDN404Mirror
/// @notice Thin wrapper around DN404Mirror for Doppler DN404 deployments.
contract DopplerDN404Mirror is DN404Mirror {
    constructor(
        address deployer
    ) DN404Mirror(deployer) { }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        address base = baseERC20();
        return DopplerDN404(base).tokenOfOwnerByIndex(owner, index);
    }
}
