// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPredictionOracle } from "src/interfaces/IPredictionOracle.sol";

/// @notice Thrown when a non-owner attempts to set the winner
error OnlyOwner();

/// @notice Thrown when attempting to set a winner after already finalized
error AlreadyFinalized();

/**
 * @title MockPredictionOracle
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice A simple oracle for testing prediction markets. Owner can set the winning token once.
 * @dev In production, this would be replaced by a more sophisticated oracle (e.g., UMA, Chainlink, etc.)
 */
contract MockPredictionOracle is IPredictionOracle {
    /// @notice Address of the winning token (address(0) until set)
    address public winningToken;

    /// @notice Whether the winner has been declared and result is final
    bool public isFinalized;

    /// @notice Owner who can set the winner
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Sets the winning token for this oracle/market
     * @dev Can only be called once by the owner
     * @param _winningToken Address of the winning entry's token
     */
    function setWinner(address _winningToken) external {
        require(msg.sender == owner, OnlyOwner());
        require(!isFinalized, AlreadyFinalized());

        winningToken = _winningToken;
        isFinalized = true;

        emit WinnerDeclared(address(this), _winningToken);
    }

    /// @inheritdoc IPredictionOracle
    function getWinner(address) external view override returns (address, bool) {
        return (winningToken, isFinalized);
    }
}
