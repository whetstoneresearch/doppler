// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { BaseDook } from "src/base/BaseDook.sol";

error InsufficientAmountLeft(PoolId poolId, address sender, uint256 amountRequested, uint256 amountLeft);

event UpdatedAmountLeft(PoolId indexed poolId, address indexed sender, uint256 amountLeft);

contract SwapRestrictorDook is BaseDook {
    mapping(PoolId poolId => bool isToken0) public isAssetToken0;
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

        if ((params.zeroForOne && !isToken0) || (!params.zeroForOne && isToken0)) {
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
