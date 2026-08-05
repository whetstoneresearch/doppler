// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal interface for Doppler's DERC20 vesting token.
interface IDERC20 {
    function vestingDuration() external view returns (uint256);
    function release() external;
}
