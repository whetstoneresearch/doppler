// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { AuthTransfer, IAuthBridgeOracle } from "src/interfaces/IAuthBridgeOracle.sol";

/// @notice Thrown when the configured oracle address is zero.
error AuthBridgeTransferExecutor_InvalidOracle(address oracle);

/// @notice Thrown when the token's transfer lane has been disabled.
error AuthBridgeTransferExecutor_AuthorizationDisabled(address token);

/**
 * @title Auth-Bridge Transfer Executor
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Route for token transfers authorized by AuthBridgeOracle.
 * @dev Disabled lanes revert instead of becoming an open `transferFrom` route.
 */
contract AuthBridgeTransferExecutor {
    /// @notice Shared Auth Bridge oracle.
    IAuthBridgeOracle public immutable AUTH_BRIDGE_ORACLE;

    /// @param authBridgeOracle Shared Auth Bridge oracle.
    constructor(address authBridgeOracle) {
        if (authBridgeOracle == address(0)) revert AuthBridgeTransferExecutor_InvalidOracle(authBridgeOracle);
        AUTH_BRIDGE_ORACLE = IAuthBridgeOracle(authBridgeOracle);
    }

    /**
     * @notice Transfers tokens after consuming a user and auth-signer authorization.
     * @dev The token holder must approve this executor before the call.
     */
    function transferWithAuthorization(
        AuthTransfer calldata transferAuth,
        bytes calldata userSig,
        bytes calldata authSig
    ) external returns (bool) {
        IAuthBridgeOracle oracle = AUTH_BRIDGE_ORACLE;
        if (oracle.isTransferAuthorizationDisabled(transferAuth.token)) {
            revert AuthBridgeTransferExecutor_AuthorizationDisabled(transferAuth.token);
        }

        oracle.authorizeTransfer(transferAuth, msg.sender, userSig, authSig);
        SafeTransferLib.safeTransferFrom(transferAuth.token, transferAuth.from, transferAuth.to, transferAuth.amount);
        return true;
    }
}
