// SPDX-License-Identifier: GPL
pragma solidity ^0.8.13;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";

/**
 * @title Doppler Hook Interface
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hooks (Dooks) are contracts that can be hooked to a Uniswap V4 pool deployed using the
 * Dook Multicurve Initializer, they allow for custom logic to be executed during specific pool events such
 * as initialization, swaps and graduation
 */
interface IDook {
    /**
     * @notice Called during the pool initialization process or when the hook is added to an existing pool
     * @param asset Address of the asset token
     * @param data Extra data to pass to the hook
     */
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external;

    /**
     * @notice Called before every swap executed on the pool
     * @param sender Address of the swap sender
     * @param key PoolKey of the pool where the swap is executed
     * @param params Swap parameters as defined in IPoolManager
     * @param data Extra data to pass to the hook
     */
    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external;

    /**
     * @notice Called when the pool graduates
     * @param asset Address of the asset token
     * @param data Extra data to pass to the hook
     */
    function onGraduation(address asset, PoolKey calldata key, bytes calldata data) external;
}
