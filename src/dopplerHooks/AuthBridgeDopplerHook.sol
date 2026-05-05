// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDopplerHookInitializer } from "src/base/BaseDopplerHookInitializer.sol";
import { AuthBridgeInitData, AuthSwap, IAuthBridgeOracle } from "src/interfaces/IAuthBridgeOracle.sol";

/// @notice Thrown when swap authorization is enabled but no hook data was provided.
error AuthBridge_MissingHookData();

/// @notice Thrown when the configured oracle address is zero.
error AuthBridge_InvalidOracle(address oracle);

/// @notice Thrown when a pool is initialized more than once.
error AuthBridge_PoolAlreadyInitialized(PoolId poolId);

/// @notice Thrown when swap auth is requested for an unknown pool.
error AuthBridge_PoolNotInitialized(PoolId poolId);

/// @notice Data passed in hookData for swap authorization.
struct AuthBridgeData {
    /// @notice User whose signature authorizes the swap.
    address user;

    /// @notice Swap executor that must match the sender reported by `DopplerHookInitializer`.
    address executor;

    /// @notice Unordered nonce consumed for this user and pool.
    bytes32 nonce;

    /// @notice Last timestamp at which the authorization is valid.
    uint64 deadline;

    /// @notice Signature from `user` over the reconstructed swap authorization.
    bytes userSig;

    /// @notice Signature from the lane's auth signer over the reconstructed swap authorization.
    bytes authSig;
}

/**
 * @title Auth-Bridge Doppler Hook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook that gates swaps using two-party EIP-712 signature authorization.
 * @dev The hook only authorizes swaps. It does not alter swap accounting and always returns no hook delta.
 */
contract AuthBridgeDopplerHook is BaseDopplerHookInitializer {
    using PoolIdLibrary for PoolKey;

    address internal constant NO_CURRENCY_ADDRESS = address(0);
    int128 internal constant NO_HOOK_DELTA = 0;

    /// @notice Shared Auth Bridge oracle used by all pools on this hook.
    IAuthBridgeOracle public immutable AUTH_BRIDGE_ORACLE;

    /// @notice Doppler asset for each initialized pool.
    mapping(PoolId poolId => address asset) public poolAsset;

    /**
     * @param initializer DopplerHookInitializer allowed to call this hook.
     * @param authBridgeOracle Shared Auth Bridge oracle.
     */
    constructor(address initializer, address authBridgeOracle) BaseDopplerHookInitializer(initializer) {
        if (authBridgeOracle == address(0)) revert AuthBridge_InvalidOracle(authBridgeOracle);
        AUTH_BRIDGE_ORACLE = IAuthBridgeOracle(authBridgeOracle);
    }

    /// @inheritdoc BaseDopplerHookInitializer
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        PoolId poolId = key.toId();
        if (poolAsset[poolId] != address(0)) revert AuthBridge_PoolAlreadyInitialized(poolId);

        AuthBridgeInitData memory initData = abi.decode(data, (AuthBridgeInitData));
        poolAsset[poolId] = asset;
        AUTH_BRIDGE_ORACLE.initializeSwapAuthorization(poolId, initData.authSigner, initData.disableAuthority);
    }

    /// @inheritdoc BaseDopplerHookInitializer
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata data
    ) internal override returns (Currency, int128) {
        PoolId poolId = key.toId();
        address asset = poolAsset[poolId];
        if (asset == address(0)) revert AuthBridge_PoolNotInitialized(poolId);

        IAuthBridgeOracle oracle = AUTH_BRIDGE_ORACLE;
        if (oracle.isSwapAuthorizationDisabled(poolId)) {
            return _noSwapAdjustment();
        }

        if (data.length == 0) revert AuthBridge_MissingHookData();
        AuthBridgeData memory authData = abi.decode(data, (AuthBridgeData));

        AuthSwap memory swapAuth = AuthSwap({
            user: authData.user,
            executor: authData.executor,
            asset: asset,
            poolId: PoolId.unwrap(poolId),
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            nonce: authData.nonce,
            deadline: authData.deadline
        });

        oracle.authorizeSwap(swapAuth, sender, authData.userSig, authData.authSig);
        return _noSwapAdjustment();
    }

    function _noSwapAdjustment() internal pure returns (Currency, int128) {
        return (Currency.wrap(NO_CURRENCY_ADDRESS), NO_HOOK_DELTA);
    }
}
