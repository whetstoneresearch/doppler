// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Interface implemented by external contracts supplying top-up liquidity
interface IDistributionTopUpSource {
    /// @notice Transfer any available numeraire top-up for a given launch
    /// @param asset The launch asset token
    /// @param numeraire The numeraire token (address(0) for ETH)
    /// @return amount Amount transferred (used for monitoring)
    function pullTopUp(address asset, address numeraire) external returns (uint256 amount);
}
