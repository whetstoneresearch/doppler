// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDook } from "src/base/BaseDook.sol";

/// @notice Thrown when a swap request exceeds the amount left to buy for the sender
error InsufficientAmountLeft(PoolId poolId, address sender, uint256 amountRequested, uint256 amountLeft);

/// @notice Emitted when the amount left to buy for a sender is updated
event UpdatedAmountLeft(PoolId indexed poolId, address indexed sender, uint256 amountLeft);

/**
 * @title Swap Restrictor Dook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook allowing to limit the amount an address can swap for a given asset in a pool
 */
contract SwapRestrictorDook is BaseDook {
    /// @notice Returns true if the asset token is the `currency0` of the Uniswap V4 pool
    mapping(PoolId poolId => bool isToken0) public isAssetToken0;

    /// @notice Returns the amount left to buy for a given sender and Uniswap V4 pool
    mapping(PoolId poolId => mapping(address sender => uint256 amountLeft)) public amountLeftOf;

    /// @param initializer Address of the Dook Multicurve Initializer contract
    constructor(address initializer) BaseDook(initializer) { }

    /// @inheritdoc BaseDook
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        (address[] memory approved, uint256 maxAmount) = abi.decode(data, (address[], uint256));

        PoolId poolId = key.toId();
        isAssetToken0[poolId] = Currency.unwrap(key.currency0) == asset;

        for (uint256 i = 0; i < approved.length; i++) {
            amountLeftOf[poolId][approved[i]] = maxAmount;
            emit UpdatedAmountLeft(poolId, approved[i], maxAmount);
        }
    }

    /// @inheritdoc BaseDook
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata
    ) internal override {
        bool isToken0 = isAssetToken0[key.toId()];

        if (params.zeroForOne != isToken0) {
            uint256 amountRequested = isToken0 ? uint128(balanceDelta.amount0()) : uint128(balanceDelta.amount1());
            PoolId poolId = key.toId();
            require(
                amountLeftOf[poolId][sender] >= amountRequested,
                InsufficientAmountLeft(poolId, sender, amountRequested, amountLeftOf[poolId][sender])
            );
            amountLeftOf[poolId][sender] -= amountRequested;
            emit UpdatedAmountLeft(poolId, sender, amountLeftOf[poolId][sender]);
        }
    }
}
