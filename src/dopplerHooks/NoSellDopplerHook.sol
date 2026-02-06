// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";

/// @notice Thrown when a user attempts to sell tokens back to the pool
error SellsNotAllowed();

/**
 * @title NoSellDopplerHook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice DopplerHook that blocks sells (asset -> numeraire) while allowing buys (numeraire -> asset).
 * @dev Used for prediction markets where the pot must remain locked after purchases.
 * In a parimutuel system, if users could sell tokens back:
 * - The pot would decrease, breaking pro-rata calculations
 * - Arbitrage between selling back and peer-to-peer trading would be possible
 * - The "all-in" commitment property of prediction markets would be lost
 */
contract NoSellDopplerHook is BaseDopplerHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Returns true if the asset token is `currency0` of the Uniswap V4 pool
    mapping(PoolId poolId => bool isToken0) public isAssetToken0;

    /// @param initializer Address of the DopplerHookInitializer contract
    constructor(address initializer) BaseDopplerHook(initializer) { }

    /// @inheritdoc BaseDopplerHook
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata) internal override {
        PoolId poolId = key.toId();
        isAssetToken0[poolId] = Currency.unwrap(key.currency0) == asset;
    }

    /// @inheritdoc BaseDopplerHook
    /// @dev Reverts if the swap direction is a sell (asset -> numeraire).
    /// While the swap executes before the revert, the entire transaction fails atomically.
    /// The gas cost of the failed swap is borne by the seller, which is the correct incentive structure.
    function _onSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal view override returns (Currency, int128) {
        bool isToken0 = isAssetToken0[key.toId()];

        // Selling asset means:
        // - If asset is token0: zeroForOne = true (selling token0 for token1)
        // - If asset is token1: zeroForOne = false (selling token1 for token0)
        // So: isSell = (isToken0 == zeroForOne)
        bool isSell = (isToken0 == params.zeroForOne);

        require(!isSell, SellsNotAllowed());

        return (Currency.wrap(address(0)), 0);
    }
}
