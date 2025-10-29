// SPDX-License-Identifier: GPL
pragma solidity ^0.8.13;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";

interface IDook {
    function onInitialization(address asset, bytes calldata data) external;

    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external;

    function onGraduation(address asset, bytes calldata data) external;
}
