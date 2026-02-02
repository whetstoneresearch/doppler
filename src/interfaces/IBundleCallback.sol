// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Result of a successful bundle creation
/// @param asset The created asset token
/// @param pool The created pool
/// @param governance The deployed governance contract
/// @param timelock The deployed timelock contract
/// @param migrationPool The created migration pool
struct CreateResult {
    address asset;
    address pool;
    address governance;
    address timelock;
    address migrationPool;
}

/// @notice A token transfer to be executed
/// @param token The token to transfer
/// @param to The recipient address
/// @param amount The amount to transfer
struct Transfer {
    address token;
    address to;
    uint256 amount;
}

/// @notice A generic call to be executed
/// @param target The target contract address
/// @param value The ETH value to send
/// @param data The call data
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @notice Interface for callbacks during bundle creation
/// @dev Allows external contracts to plan additional actions based on creation results
interface IBundleCallback {
    /// @notice Plan additional transfers and calls based on creation results
    /// @param result The result of the bundle creation
    /// @param data Additional encoded data for planning
    /// @return transfers Array of token transfers to execute
    /// @return calls Array of generic calls to execute
    function plan(CreateResult calldata result, bytes calldata data)
        external
        returns (Transfer[] memory transfers, Call[] memory calls);
}
