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
 * @dev Validates beneficiaries array, ensures protocol owner compliance and store the shares
 * @param beneficiaries Array with sorted addresses and shares specified in WAD (with a total sum of 1 WAD)
 * @param protocolOwner Address of the protocol owner, required as a beneficiary with a minimum of shares
 * @param protocolOwnerShares Minimum of shares required for the protocol owner
 * @param poolId Id of the Uniswap V4 pool, if not zero the shares will be stored in the provided mapping
 * @param getShares Mapping of pool ids to beneficiary addresses to their respective shares
 */
function storeBeneficiaries(
    BeneficiaryData[] memory beneficiaries,
    address protocolOwner,
    uint96 protocolOwnerShares,
    PoolId poolId,
    mapping(PoolId => mapping(address => uint256)) storage getShares
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
        if (PoolId.unwrap(poolId) != bytes32(0)) getShares[poolId][prevBeneficiary] = beneficiary.shares;
    }

    require(totalShares == WAD, InvalidTotalShares());
    require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
}

/**
 * @dev Validates beneficiaries array, ensures protocol owner compliance
 * @param beneficiaries Array with sorted addresses and shares specified in WAD (with a total sum of 1 WAD)
 * @param protocolOwner Address of the protocol owner, required as a beneficiary with a minimum of shares
 * @param protocolOwnerShares Minimum of shares required for the protocol owner
 */
function validateBeneficiaries(
    BeneficiaryData[] memory beneficiaries,
    address protocolOwner,
    uint96 protocolOwnerShares
) pure {
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
    }

    require(totalShares == WAD, InvalidTotalShares());
    require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
}
