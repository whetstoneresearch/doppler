// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { PoolId } from "@v4-core/types/PoolId.sol";

/// @notice Per-pool Auth Bridge settings passed to `AuthBridgeDopplerHook` during pool initialization.
struct AuthBridgeInitData {
    /// @notice Signer that co-signs authorized actions.
    address authSigner;
    /// @notice Address allowed to permanently disable swap authorization for the initialized pool.
    address disableAuthority;
}

/// @notice Swap authorization signed by both the user and auth signer.
struct AuthSwap {
    /// @notice User whose signature authorizes the swap.
    address user;
    /// @notice Swap executor that must match the caller reported by the trusted hook.
    address executor;
    /// @notice Doppler asset associated with the initialized pool.
    address asset;
    /// @notice Uniswap V4 pool id for the authorized swap.
    bytes32 poolId;
    /// @notice Swap direction from the Uniswap V4 swap params.
    bool zeroForOne;
    /// @notice Amount from the Uniswap V4 swap params.
    int256 amountSpecified;
    /// @notice Price limit from the Uniswap V4 swap params.
    uint160 sqrtPriceLimitX96;
    /// @notice Unordered nonce consumed for this user and pool.
    bytes32 nonce;
    /// @notice Last timestamp at which the authorization is valid.
    uint64 deadline;
}

/// @notice Token transfer authorization signed by both the token holder and auth signer.
struct AuthTransfer {
    /// @notice ERC20 token being transferred.
    address token;
    /// @notice Token holder whose signature authorizes the transfer.
    address from;
    /// @notice Transfer recipient.
    address to;
    /// @notice Transfer amount.
    uint256 amount;
    /// @notice Transfer executor that must match `msg.sender`.
    address executor;
    /// @notice Unordered nonce consumed for this holder and token.
    bytes32 nonce;
    /// @notice Last timestamp at which the authorization is valid.
    uint64 deadline;
}

/// @notice Shared Auth Bridge authorizer for Doppler swaps and authorized token transfers.
interface IAuthBridgeOracle {
    /**
     * @notice Initializes swap authorization for a pool.
     * @dev Intended to be called by a trusted hook during pool initialization.
     */
    function initializeSwapAuthorization(PoolId poolId, address authSigner, address disableAuthority) external;

    /// @notice Initializes transfer authorization for a token.
    function initializeTransferAuthorization(address token, address authSigner, address disableAuthority) external;

    /// @notice Updates whether a hook or route may call authorization methods.
    function setTrustedCaller(address caller, bool trusted) external;

    /// @notice Consumes a swap authorization or reverts.
    /// @param sender Actual swap executor reported by the trusted hook.
    function authorizeSwap(
        AuthSwap calldata swapAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external;

    /// @notice Consumes a transfer authorization or reverts.
    /// @param sender Actual transfer executor.
    function authorizeTransfer(
        AuthTransfer calldata transferAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external;

    /// @notice Permanently disables swap authorization for a pool. Callable only by that pool's disable authority.
    function disableSwapAuthorization(PoolId poolId) external;

    /// @notice Permanently disables transfer authorization for a token. Callable only by that token's disable authority.
    function disableTransferAuthorization(address token) external;

    /// @notice Returns true once swap authorization has been permanently disabled for a pool.
    function isSwapAuthorizationDisabled(PoolId poolId) external view returns (bool);

    /// @notice Returns true once transfer authorization has been permanently disabled for a token.
    function isTransferAuthorizationDisabled(address token) external view returns (bool);
}
