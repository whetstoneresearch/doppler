// SPDX-License-Identifier: GPL
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title Doppler Hook Migrator Interface
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook Migrators are contracts that can be hooked to Uniswap V4 pools deployed using the
 * DopplerHookMigrator, they allow for custom logic to be executed during specific pool events such
 * as initialization, swaps
 */
interface IDopplerHookMigrator {
    /**
     * @notice Called during the pool initialization process or when the hook is added to an existing pool
     * @param asset Address of the asset token
     * @param key Key of the Uniswap V4 pool being initialized
     * @param data Extra data to pass to the hook
     */
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external;

    /**
     * @notice Called before every swap executed
     * @param sender Address of the swap sender
     * @param key Key of the Uniswap V4 pool where the swap is executed
     * @param params Swap parameters as defined in IPoolManager
     * @param data Extra data to pass to the hook
     */
    function onBeforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external;

    /**
     * @notice Called after every swap executed
     * @param sender Address of the swap sender
     * @param key Key of the Uniswap V4 pool where the swap is executed
     * @param params Swap parameters as defined in IPoolManager
     * @param delta Amount owed to the caller (positive) or owed to the pool (negative)
     * @param data Extra data to pass to the hook
     * @return feeCurrency Currency being charged (unspecified currency derived from the swap)
     * @return hookDelta Positive amount if the hook is owed currency, false otherwise
     */
    function onAfterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (Currency feeCurrency, int128 hookDelta);
}
