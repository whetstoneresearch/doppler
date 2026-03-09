// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

/// @title Base Minimal Hook
/// @notice Minimal hook base that only exposes the callbacks used by the inheriting contract.
abstract contract BaseMinimalHook is IHooks, ImmutableState {
    error HookNotImplemented();

    constructor() {
        validateHookAddress(address(this));
    }

    /// @notice Returns the hook permissions expected by the deployed address.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    /// @dev Validates the deployed hook address against the declared permissions.
    function validateHookAddress(address self) internal pure virtual {
        Hooks.validateHookPermissions(IHooks(self), getHookPermissions());
    }

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external onlyPoolManager returns (bytes4) {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal virtual returns (bytes4);

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta);

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta);

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal virtual returns (bytes4, BeforeSwapDelta, uint24);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, int128);

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }
}
