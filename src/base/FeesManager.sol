// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

abstract contract FeesManager {
    mapping(address => uint256 fees) public cumulatedFees;
    mapping(address => mapping(address beneficiary => uint256 fees)) public collectedFees;

    /*
    function collectFees(address asset) external returns (uint256 fees0, uint256 fees1) {


        (uint256 amount0, uint256 amount1) = collectFees(asset);
    }
    */

    /// @dev Calls an external contract like Uniswap V4 to collect fees
    function collectFees(
        address
    ) internal virtual returns (uint256, uint256);
}
