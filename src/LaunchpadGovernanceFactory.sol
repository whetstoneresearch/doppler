// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/**
 * @title LaunchpadGovernanceFactory
 * @notice A governance factory that returns a multisig instead of deploying actual governance contracts
 * @dev This is used for tokens that do not require on-chain governance, but want to sweep unused funds
 */
contract LaunchpadGovernanceFactory is IGovernanceFactory {
    /// @inheritdoc IGovernanceFactory
    function create(
        address,
        bytes calldata data
    ) external pure returns (address governance, address timelockController) {
        address multisig = abi.decode(data, (address));
        return (DEAD_ADDRESS, multisig);
    }
}
