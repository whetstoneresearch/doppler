// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPredictionOracle
 * @notice Interface for prediction market oracles that determine winning entries
 * @dev Oracles must implement this interface to be compatible with PredictionMigrator
 */
interface IPredictionOracle {
    /// @notice Emitted when a winner is declared for a market
    /// @param oracle The oracle address (which defines the market)
    /// @param winningToken The address of the winning entry's token
    event WinnerDeclared(address indexed oracle, address indexed winningToken);

    /// @notice Returns the winning token for a market
    /// @param oracle The oracle address (which defines the market)
    /// @return winningToken The address of the winning entry's token (address(0) if not yet declared)
    /// @return isFinalized Whether the result is final and claims can proceed
    function getWinner(address oracle) external view returns (address winningToken, bool isFinalized);
}
