// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

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
 * @param pool Address of the pool
 * @param beneficiary Address of the beneficiary receiving the fees
 * @param fees0 Amount of fees collected in token0
 * @param fees1 Amount of fees collected in token1
 */
event Collect(address indexed pool, address indexed beneficiary, uint256 fees0, uint256 fees1);

abstract contract FeesManager {
    mapping(address asset => uint256 cumulatedFees0) public getCumulatedFees0;
    mapping(address asset => uint256 cumulatedFees1) public getCumulatedFees1;

    mapping(address asset => mapping(address beneficiary => uint256 lastCumulatedFees0)) public getLastCumulatedFees0;
    mapping(address asset => mapping(address beneficiary => uint256 lastCumulatedFees1)) public getLastCumulatedFees1;

    mapping(address asset => mapping(address beneficiary => uint256 shares)) public getShares;

    function _validateBeneficiaries(
        address asset,
        address protocolOwner,
        BeneficiaryData[] memory beneficiaries
    ) internal {
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

            getShares[asset][prevBeneficiary] = beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }

    function collectFees(
        address asset
    ) external returns (uint256 fees0, uint256 fees1) {
        (fees0, fees1) = _collectFees(asset);

        getCumulatedFees0[asset] += fees0;
        getCumulatedFees1[asset] += fees1;

        uint256 shares = getShares[asset][msg.sender];

        if (shares > 0) {
            uint256 delta0 = getCumulatedFees0[asset] - getLastCumulatedFees0[asset][msg.sender];
            uint256 amount0 = delta0 * shares / WAD;
            getLastCumulatedFees0[asset][msg.sender] = getCumulatedFees0[asset];
            // if (amount0 > 0) state.poolKey.currency0.transfer(msg.sender, amount0);

            uint256 delta1 = getCumulatedFees1[asset] - getLastCumulatedFees1[asset][msg.sender];
            uint256 amount1 = delta1 * shares / WAD;
            getLastCumulatedFees1[asset][msg.sender] = getCumulatedFees1[asset];
            // if (amount1 > 0) state.poolKey.currency1.transfer(msg.sender, amount1);

            emit Collect(asset, msg.sender, amount0, amount1);
        }
    }

    /// @dev Calls an external contract like Uniswap V4 to collect fees
    function _collectFees(
        address
    ) internal virtual returns (uint256, uint256);
}
