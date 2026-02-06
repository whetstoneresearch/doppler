// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Minimal interface for burnable tokens
/// @dev Both DERC20 and CloneERC20 implement burn(uint256)
interface IBurnable {
    /// @notice Burns `amount` of tokens from the caller's balance
    /// @param amount Amount of tokens to burn
    function burn(uint256 amount) external;
}
