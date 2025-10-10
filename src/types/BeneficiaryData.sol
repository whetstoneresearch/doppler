// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PoolId } from "@v4-core/types/PoolId.sol";
import { WAD } from "src/types/Wad.sol";

/// @dev Thrown when the beneficiaries are not sorted in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid (greater than WAD)
error InvalidShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when protocol owner shares don't match the minimum required
error InvalidProtocolOwnerShares(uint96 required, uint96 provided);

/// @dev Minimum shares required for the protocol owner beneficiary (5% in WAD)
uint96 constant MIN_PROTOCOL_OWNER_SHARES = uint96(WAD / 20);

/**
 * @notice Data structure for beneficiary information
 * @param beneficiary Address of the beneficiary
 * @param beneficiaries
 * @param shares Share of fees allocated to this beneficiary (in WAD)
 */
struct BeneficiaryData {
    address beneficiary;
    uint96 shares;
}

/**
 * @dev Validates an array of beneficiaries and stores them if requested. The requirements are as follows:
 * - Beneficiaries must be unique and addresses should be sorted in ascending order
 * - Each share must be greater than 0
 * - The sum of all shares must equal `WAD` (`1e18`)
 * - The protocol owner must be included as a beneficiary with at least the specified minimum shares
 * @param beneficiaries Array with sorted addresses and shares specified in WAD (with a total sum of 1 WAD)
 * @param protocolOwner Address of the protocol owner, required as a beneficiary with a minimum of shares
 * @param protocolOwnerShares Minimum of shares required for the protocol owner
 * @param poolId Pool id of the associated Uniswap V4 pool, pass `PoolId.wrap(bytes32(0))` to skip storing
 * @param storeBeneficiary Function to call to store each beneficiary (if `poolId` is not zero)
 */
function storeBeneficiaries(
    PoolId poolId,
    BeneficiaryData[] memory beneficiaries,
    address protocolOwner,
    uint96 protocolOwnerShares,
    function(PoolId, BeneficiaryData memory) storeBeneficiary
) {
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
            require(
                beneficiary.shares >= protocolOwnerShares,
                InvalidProtocolOwnerShares(protocolOwnerShares, beneficiary.shares)
            );
            foundProtocolOwner = true;
        }

        prevBeneficiary = beneficiary.beneficiary;
        totalShares += beneficiary.shares;

        // If a pool id is passed, we use it to store the shares
        if (PoolId.unwrap(poolId) != bytes32(0)) storeBeneficiary(poolId, beneficiary);
    }

    require(totalShares == WAD, InvalidTotalShares());
    require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
}
