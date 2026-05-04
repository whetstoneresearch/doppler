// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";
import { IAuthBridgeOracle, AuthSwap } from "src/interfaces/IAuthBridgeOracle.sol";

// ============ Errors ============

/// @notice Thrown when hookData is missing or cannot be decoded
error AuthBridge_MissingHookData();

/// @notice Thrown when the executor does not match the expected executor
error AuthBridge_InvalidOracle(address oracle);
error AuthBridge_OracleAlreadySet(PoolId poolId);
error AuthBridge_OracleNotSet(PoolId poolId);
error AuthBridge_Unauthorized();

// ============ Structs ============

/// @notice Data passed in hookData for swap authorization
struct AuthBridgeData {
    address user; // the user identity being authorized (EOA for P1)
    address executor; // optional: required swap executor (0 = allow any executor)
    uint64 deadline; // unix seconds timestamp
    uint64 nonce; // expected nonce for (poolId, user)
    bytes userSig; // ECDSA sig over EIP-712 digest
    bytes platformSig; // ECDSA sig over EIP-712 digest
}

/// @notice Data passed during pool initialization
struct AuthBridgeInitData {
    address oracle;
    bytes oracleData;
}

/**
 * @title Auth-Bridge Doppler Hook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook that gates swaps using two-party EIP-712 signature authorization.
 * Each swap requires both a user signature and a platform signature over the same digest.
 * @dev Auth logic (nonces, signatures, deadlines) lives in the oracle.
 */
contract AuthBridgeDopplerHook is BaseDopplerHook {
    using PoolIdLibrary for PoolKey;

    // ============ State ============

    /// @notice Oracle per pool (set once at initialization)
    mapping(PoolId poolId => address oracle) public poolOracle;

    // ============ Constructor ============

    /**
     * @param initializer Address of the DopplerHookInitializer contract
     */
    constructor(address initializer) BaseDopplerHook(initializer) { }

    // ============ Initialization ============

    /// @inheritdoc BaseDopplerHook
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        PoolId poolId = key.toId();
        if (poolOracle[poolId] != address(0)) revert AuthBridge_OracleAlreadySet(poolId);

        AuthBridgeInitData memory initData = abi.decode(data, (AuthBridgeInitData));
        if (initData.oracle == address(0)) revert AuthBridge_InvalidOracle(initData.oracle);

        poolOracle[poolId] = initData.oracle;
        IAuthBridgeOracle(initData.oracle).initialize(poolId, asset, initData.oracleData);
    }

    // ============ Swap Validation ============

    /// @inheritdoc BaseDopplerHook
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata data
    ) internal override returns (Currency, int128) {
        // 1. Decode AuthBridgeData from hookData
        if (data.length == 0) {
            revert AuthBridge_MissingHookData();
        }

        AuthBridgeData memory authData = abi.decode(data, (AuthBridgeData));

        PoolId poolId = key.toId();
        address oracle = poolOracle[poolId];
        if (oracle == address(0)) revert AuthBridge_OracleNotSet(poolId);

        AuthSwap memory swapData = AuthSwap({
            user: authData.user,
            executor: authData.executor,
            poolId: PoolId.unwrap(poolId),
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            nonce: authData.nonce,
            deadline: authData.deadline
        });

        bool authorized = IAuthBridgeOracle(oracle).isAuthorized(
            swapData,
            sender,
            authData.userSig,
            authData.platformSig
        );

        if (!authorized) revert AuthBridge_Unauthorized();

        return (Currency.wrap(address(0)), 0);
    }

}
