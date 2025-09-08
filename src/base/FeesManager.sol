// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when the new beneficiary is the same as the caller
error InvalidNewBeneficiary();

/**
 * @notice Emitted a beneficiary collects their fees
 * @param poolId Id of the Uniswap V4 pool
 * @param beneficiary Address of the beneficiary receiving the fees
 * @param fees0 Amount of fees collected in token0
 * @param fees1 Amount of fees collected in token1
 */
event Collect(PoolId indexed poolId, address indexed beneficiary, uint256 fees0, uint256 fees1);

/**
 * @notice Emitted when a beneficiary is updated
 * @param poolId Id of the Uniswap V4 pool
 * @param oldBeneficiary Address of the previous beneficiary
 * @param newBeneficiary Address of the new beneficiary
 */
event UpdateBeneficiary(PoolId poolId, address oldBeneficiary, address newBeneficiary);

/**
 * @title FeesManager
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @dev Base contract allowing the collection and distribution of fees from a Uniswap V4 pool, the fees management
 * is based on a similar mechanism used in the `MasterChef` contract from SushiSwap, allowing anyone to claim fees
 * from a pool but only distributing them to the actual `msg.sender` if they are a beneficiary, otherwise increasing
 * accumulated fees for the other beneficiaries. Fees are later computed with the following formula:
 *
 *            (cumulatedFees - lastCumulatedFees) ⋅ shares
 *    fees = ──────────────────────────────────────────────
 *                                WAD
 *
 */
abstract contract FeesManager is ReentrancyGuard {
    /// @notice Cumulated fees for the Uniswap V4 pool `poolId` denominated in token0
    mapping(PoolId poolId => uint256 cumulatedFees0) public getCumulatedFees0;

    /// @notice Cumulated fees for the Uniswap V4 pool `poolId` denominated in token1
    mapping(PoolId poolId => uint256 cumulatedFees1) public getCumulatedFees1;

    /// @notice Last `collectFees` call of a `beneficiary` for a specific `poolId` denominated in token0
    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees0)) public getLastCumulatedFees0;

    /// @notice Last `collectFees` call of a `beneficiary` for a specific `poolId` denominated in token1
    mapping(PoolId poolId => mapping(address beneficiary => uint256 lastCumulatedFees1)) public getLastCumulatedFees1;

    /// @notice Shares entitled to a `beneficiary` for the associated Uniswap V4 `poolId`
    mapping(PoolId poolId => mapping(address beneficiary => uint256 shares)) public getShares;

    /// @notice Associates `poolId` types with their corresponding Uniswap V4 pool `poolKey` types
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

    /**
     * @notice Transfers the shares of the `msg.sender` to a new `newBeneficiary` address for a specified
     * `poolId` Uniswap V4 pool, note that this function also collects the currently available fees
     * @param poolId Pool id of the Uniswap V4 pool to target
     * @param newBeneficiary Address of the new beneficiary
     */
    function updateBeneficiary(PoolId poolId, address newBeneficiary) external nonReentrant {
        require(newBeneficiary != msg.sender, InvalidNewBeneficiary());

        _releaseFees(poolId, msg.sender);
        _releaseFees(poolId, newBeneficiary);

        // If the new beneficiary had no shares before, we need to initialize their lastCumulatedFees
        if (getShares[poolId][newBeneficiary] == 0) {
            getLastCumulatedFees0[poolId][newBeneficiary] = getCumulatedFees0[poolId];
            getLastCumulatedFees1[poolId][newBeneficiary] = getCumulatedFees1[poolId];
        }

        // No need to check if shares > WAD, since we already validated this in `_storeBeneficiaries`
        getShares[poolId][newBeneficiary] += getShares[poolId][msg.sender];
        getShares[poolId][msg.sender] = 0;

        emit UpdateBeneficiary(poolId, msg.sender, newBeneficiary);
    }

    /**
     * @dev Distributes the available fees for a specified `beneficiary` address
     * @param poolId Pool id of the Uniswap V4 pool to collect fees from
     * @param beneficiary Address of the beneficiary claiming the fees
     */
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

    /**
     * @dev Called in `collectFees`, this function is meant to be overridden by a child contract and must
     * implement a mechanism to collect fees from an external party such as Uniswap V4 `PoolManager` contract
     * @param poolId Pool id representation of the Uniswap V4 pool to collect fees from
     * @return fees Collected fees denominated in `token0` and `token1` represented as a `BalanceDelta` type
     */
    function _collectFees(
        PoolId poolId
    ) internal virtual returns (BalanceDelta fees);
}
