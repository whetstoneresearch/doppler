// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { DookMulticurveInitializer } from "src/DookMulticurveInitializer.sol";
import { IDook } from "src/interfaces/IDook.sol";

/**
 * @title Uniswap V4 Hooked Multicurve Initializer Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Hooked Multicurve Initializer
 * @custom:security-contact security@whetstone.cc
 */
contract DookMulticurveHook is UniswapV4MulticurveInitializerHook {
    /// @notice Maps a poolId to its associated Doppler Hook
    mapping(PoolId poolId => address dook) public getDook;

    /**
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Hooked Multicurve Initializer contract
     */
    constructor(IPoolManager manager, address initializer) UniswapV4MulticurveInitializerHook(manager, initializer) { }

    /**
     * @notice Fetches and saves the Doppler Hook for a given poolId
     */
    function setDook(PoolId poolId, address dook) external onlyInitializer(msg.sender) {
        getDook[poolId] = dook;
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        address dook = getDook[key.toId()];
        if (dook != address(0)) IDook(dook).onSwap(sender, key, params, data);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
