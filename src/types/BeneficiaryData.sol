// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { WAD } from "src/types/Wad.sol";

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when protocol owner shares are invalid
error InvalidProtocolOwnerShares();

/// @notice Data structure for beneficiary information
/// @param beneficiary Address of the beneficiary
/// @param shares Share of fees allocated to this beneficiary (in WAD)
struct BeneficiaryData {
    address beneficiary;
    uint96 shares;
}

/**
 * @dev Validates beneficiaries array and ensures protocol owner compliance
 * @param beneficiaries Array of beneficiaries to validate
 */
function validateBeneficiaries(address protocolOwner, BeneficiaryData[] memory beneficiaries) pure {
    address prevBeneficiary;
    uint256 totalShares;
    bool foundProtocolOwner;

    for (uint256 i; i < beneficiaries.length; i++) {
        BeneficiaryData memory beneficiary = beneficiaries[i];

        // Validate ordering and shares
        require(prevBeneficiary < beneficiary.beneficiary, UnorderedBeneficiaries());
        require(beneficiary.shares > 0, InvalidShares());

        // Check for protocol owner and validate minimum share requirement
        if (beneficiary.beneficiary == protocolOwner) {
            require(beneficiary.shares >= WAD / 20, InvalidProtocolOwnerShares());
            foundProtocolOwner = true;
        }

        prevBeneficiary = beneficiary.beneficiary;
        totalShares += beneficiary.shares;
    }

    require(totalShares == WAD, InvalidTotalShares());
    require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
}
