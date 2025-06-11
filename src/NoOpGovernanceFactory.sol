// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

/**
 * @title NoOpGovernanceFactory
 * @notice A governance factory that returns dummy addresses instead of deploying actual governance contracts
 * @dev This is used for tokens that don't require governance mechanisms
 */
contract NoOpGovernanceFactory is IGovernanceFactory {
    /// @notice The dummy address returned for both governance and timelock
    /// @dev Using 0xdead as it's a well-known burn address
    address public constant DEAD_ADDRESS = address(0xdead);

    /**
     * @notice Creates no-op governance by returning dummy addresses
     * @dev Parameters are ignored as no contracts are deployed
     * @return governance The dummy governance address (0xdead)
     * @return timelockController The dummy timelock address (0xdead)
     */
    function create(
        address, // asset (unused)
        bytes calldata // governanceData (unused)
    ) external pure returns (address governance, address timelockController) {
        // Return dummy addresses instead of deploying contracts
        return (DEAD_ADDRESS, DEAD_ADDRESS);
    }
}