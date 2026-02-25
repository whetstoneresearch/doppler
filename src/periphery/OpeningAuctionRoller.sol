// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

/// @notice Thrown when the caller is not the PoolManager
error SenderNotPoolManager();

/// @notice Simple helper to roll an OpeningAuction position to a new tick.
/// @dev Users must approve this contract for token transfers before rolling.
contract OpeningAuctionRoller is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    struct RollParams {
        PoolKey key;
        int24 oldTickLower;
        bytes32 oldSalt;
        int24 newTickLower;
        bytes32 newSalt;
        uint128 liquidity;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams oldParams;
        IPoolManager.ModifyLiquidityParams newParams;
        bytes hookData;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Burn an out-of-range position and mint a new one in a single call.
    function roll(RollParams calldata params) external payable returns (BalanceDelta delta) {
        bytes memory hookData = abi.encode(msg.sender);

        IPoolManager.ModifyLiquidityParams memory oldParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.oldTickLower,
            tickUpper: params.oldTickLower + params.key.tickSpacing,
            liquidityDelta: -int256(uint256(params.liquidity)),
            salt: params.oldSalt
        });

        IPoolManager.ModifyLiquidityParams memory newParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.newTickLower,
            tickUpper: params.newTickLower + params.key.tickSpacing,
            liquidityDelta: int256(uint256(params.liquidity)),
            salt: params.newSalt
        });

        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData({ sender: msg.sender, key: params.key, oldParams: oldParams, newParams: newParams, hookData: hookData }))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (BalanceDelta deltaOld,) = poolManager.modifyLiquidity(data.key, data.oldParams, data.hookData);
        (BalanceDelta deltaNew,) = poolManager.modifyLiquidity(data.key, data.newParams, data.hookData);
        BalanceDelta delta = deltaOld + deltaNew;

        _settleDeltas(data.key, data.sender, delta);

        return abi.encode(delta);
    }

    function _settleDeltas(PoolKey memory key, address sender, BalanceDelta delta) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            _settleCurrency(key.currency0, sender, uint256(uint128(-amount0)));
        } else if (amount0 > 0) {
            poolManager.take(key.currency0, sender, uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            _settleCurrency(key.currency1, sender, uint256(uint128(-amount1)));
        } else if (amount1 > 0) {
            poolManager.take(key.currency1, sender, uint256(uint128(amount1)));
        }
    }

    function _settleCurrency(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
            return;
        }

        poolManager.sync(currency);
        if (payer != address(this)) {
            SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        }
        poolManager.settle();
    }
}
