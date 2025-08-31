// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
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

/**
 * @notice Emitted when a collect event is called
 * @param beneficiary Address of the beneficiary receiving the fees
 * @param fees0 Amount of fees collected in token0
 * @param fees1 Amount of fees collected in token1
 */
event Collect(PoolId indexed poolId, address indexed beneficiary, uint256 fees0, uint256 fees1);

/// @notice Emitted when a beneficiary is updated
/// @param oldBeneficiary Previous beneficiary address
/// @param newBeneficiary New beneficiary address
event UpdateBeneficiary(PoolId poolId, address oldBeneficiary, address newBeneficiary);

/**
 * @title FeesManager
 * @author Whetstone Research
 * @dev Base contract allowing the collection and distribution of fees from a Uniswap V4 pool, the fees management
 * is based on a similar mechanism used by the `MasterChef` contract, allowing anyone to claim the fees from the pool
 * but only distributing them to the actual `msg.sender` if they are a beneficiary of the position
 * @custom:security-contact security@whetstone.cc
 */
abstract contract FeesManager is ReentrancyGuard {
    mapping(PoolId poolId => uint256 cumulatedFees0) public getCumulatedFees0;
    mapping(PoolId poolId => uint256 cumulatedFees1) public getCumulatedFees1;

    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees0)) public getLastCumulatedFees0;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees1)) public getLastCumulatedFees1;

    mapping(PoolId poolId => mapping(address beneficiary => uint256 shares)) public getShares;

    mapping(PoolId poolId => PoolKey poolKey) public getPoolKey;

    /**
     * @notice Collects fees from a locked Uniswap V4 pool, distributes to the caller if applicable
     * @dev Collected fees are now held in this contract until they are claimed by their beneficiary
     * @return fees0 Total fees collected in token0 since last collection
     * @return fees1 Total fees collected in token1 since last collection
     */
    function collectFees(
        PoolId poolId
    ) external nonReentrant returns (uint128 fees0, uint128 fees1) {
        BalanceDelta fees = _collectFees(poolId);
        fees0 = uint128(fees.amount0());
        fees1 = uint128(fees.amount1());

        getCumulatedFees0[poolId] += fees0;
        getCumulatedFees1[poolId] += fees1;

        _releaseFees(poolId, msg.sender);
    }

    /// @notice Updates the beneficiary address for a position
    /// @param newBeneficiary New beneficiary address
    function updateBeneficiary(PoolId poolId, address newBeneficiary) external nonReentrant {
        _releaseFees(poolId, msg.sender);
        getShares[poolId][newBeneficiary] = getShares[poolId][msg.sender];
        getShares[poolId][msg.sender] = 0;
        getLastCumulatedFees0[poolId][newBeneficiary] = getCumulatedFees0[poolId];
        getLastCumulatedFees1[poolId][newBeneficiary] = getCumulatedFees1[poolId];

        emit UpdateBeneficiary(poolId, msg.sender, newBeneficiary);
    }

    function _storeBeneficiaries(
        PoolId poolId,
        address protocolOwner,
        BeneficiaryData[] memory beneficiaries
    ) internal {
        address prevBeneficiary;
        uint256 totalShares;
        bool foundProtocolOwner;

        for (uint256 i; i != beneficiaries.length; ++i) {
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

            getShares[poolId][prevBeneficiary] = beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }

    /// @notice Releases fees to a beneficiary
    /// @param beneficiary Address to release fees to
    function _releaseFees(PoolId poolId, address beneficiary) internal {
        uint256 shares = getShares[poolId][beneficiary];

        if (shares > 0) {
            PoolKey memory poolKey = getPoolKey[poolId];
            uint256 delta0 = getCumulatedFees0[poolId] - getLastCumulatedFees0[poolId][beneficiary];
            uint256 amount0 = delta0 * shares / WAD;
            getLastCumulatedFees0[poolId][beneficiary] = getCumulatedFees0[poolId];
            if (amount0 > 0) poolKey.currency0.transfer(beneficiary, amount0);

            uint256 delta1 = getCumulatedFees1[poolId] - getLastCumulatedFees1[poolId][beneficiary];
            uint256 amount1 = delta1 * shares / WAD;
            getLastCumulatedFees1[poolId][beneficiary] = getCumulatedFees1[poolId];
            if (amount1 > 0) poolKey.currency1.transfer(beneficiary, amount1);

            emit Collect(poolId, beneficiary, amount0, amount1);
        }
    }

    /// @dev Calls an external contract like Uniswap V4 to collect fees
    function _collectFees(
        PoolId poolId
    ) internal virtual returns (BalanceDelta fees);
}
