// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";

/**
 * @title TeamGovernanceFactory
 * @notice A governance factory that returns a multisig instead of deploying actual governance contracts
 * @dev This is used for tokens that do not require on-chain governance, but want to sweep unused funds
 */
contract TeamGovernanceFactory is IGovernanceFactory {
    /// @notice The dummy address returned for governance
    /// @dev Using 0xdead as it's a well-known burn address
    address public constant DEAD_ADDRESS = address(0xdead);

    /**
     * @notice Creates team governance by returning provided team address for the timelock
     * @dev Provide a wallet address to sweep funds into
     * @return governance The dummy governance address (0xdead)
     * @return timelockController The wallet which excess dust will be swept to
     */
    function create(
        address, // asset (unused)
        bytes calldata data
    ) external pure returns (address governance, address timelockController) {
        (address teamWallet) = abi.decode(data, (address));

        return (DEAD_ADDRESS, teamWallet);
    }
}
