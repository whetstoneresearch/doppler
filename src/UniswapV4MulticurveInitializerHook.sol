// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";

/// @notice Thrown when the caller is not the Uniswap V4 Multicurve Initializer
error OnlyInitializer();

/**
 * @title Uniswap V4 Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Multicurve Initializer to restrict liquidity
 * addition in a Uniswap V4 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4MulticurveInitializerHook is BaseHook {
    /// @notice Address of the Uniswap V4 Multicurve Initializer contract
    address public immutable initializer;

    /// @notice Modifier to ensure the caller is the Uniswap V4 Multicurve Initializer
    /// @param sender Address of the caller
    modifier onlyInitializer(
        address sender
    ) {
        if (sender != initializer) revert OnlyInitializer();
        _;
    }

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer_ Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(IPoolManager manager, UniswapV4MulticurveInitializer initializer_) BaseHook(manager) {
        initializer = address(initializer_);
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override onlyInitializer(sender) returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
