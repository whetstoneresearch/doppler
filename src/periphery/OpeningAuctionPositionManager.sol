// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

/// @notice Thrown when the caller is not the PoolManager.
error SenderNotPoolManager();

/// @notice Thrown when hookData does not contain an owner.
error HookDataMissingOwner();

/// @notice Thrown when hookData owner does not match the caller.
error HookDataOwnerMismatch();

/// @notice Minimal position manager for OpeningAuction bids.
/// @dev Enforces that hookData owner matches msg.sender to prevent unauthorized removals.
contract OpeningAuctionPositionManager is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    IPoolManager public immutable poolManager;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        address owner = _decodeOwner(hookData);
        if (owner != msg.sender) revert HookDataOwnerMismatch();
        delta = _modifyLiquidity(key, params, hookData, msg.sender);
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) external returns (BalanceDelta delta) {
        delta = _modifyLiquidity(key, params, abi.encode(msg.sender), msg.sender);
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.params, data.hookData);

        _settleDeltas(data.key, data.sender, delta);

        return abi.encode(delta);
    }

    function _modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData,
        address sender
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(sender, key, params, hookData))),
            (BalanceDelta)
        );
    }

    function _settleDeltas(PoolKey memory key, address payer, BalanceDelta delta) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            _settleCurrency(key.currency0, payer, uint256(uint128(-amount0)));
        } else if (amount0 > 0) {
            poolManager.take(key.currency0, payer, uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            _settleCurrency(key.currency1, payer, uint256(uint128(-amount1)));
        } else if (amount1 > 0) {
            poolManager.take(key.currency1, payer, uint256(uint128(amount1)));
        }
    }

    function _settleCurrency(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (payer != address(this)) {
            SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        }
        poolManager.settle();
    }

    function _decodeOwner(bytes calldata hookData) internal pure returns (address owner) {
        if (hookData.length == 20) {
            assembly {
                owner := shr(96, calldataload(hookData.offset))
            }
        } else if (hookData.length >= 32) {
            owner = abi.decode(hookData, (address));
        } else {
            revert HookDataMissingOwner();
        }
    }
}
