// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";

/// @notice Thrown when the caller is not the Uniswap V4 Migrator
error OnlyMigrator();

/// @notice Thrown when the caller is not the contract deployer
error OnlyDeployer();

/**
 * @notice Emitted when liquidity is modified
 * @param key Key of the related pool
 * @param params Parameters of the liquidity modification
 */
event ModifyLiquidity(PoolKey key, IPoolManager.ModifyLiquidityParams params);

/**
 * @title Uniswap V4 Migrator Hook
 * @author Whetstone Research
 * @notice Hook for the Uniswap V4 Migrator to restrict pool initialization of a
 * v4 pool to the Uniswap V4 Migrator
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4MigratorHook is BaseHook {
    /// @notice Address of the Uniswap V4 Migrator contract
    address public immutable migrator;

    /// @notice Modifier to ensure the caller is the Uniswap V4 Migrator
    /// @param sender Address of the caller
    modifier onlyMigrator(
        address sender
    ) {
        if (sender != migrator) revert OnlyMigrator();
        _;
    }

    /// @notice Constructor for the Uniswap V4 Migrator Hook
    /// @param manager Address of the Uniswap V4 Pool Manager
    /// @param migrator_ Address of the Uniswap V4 Migrator contract
    constructor(IPoolManager manager, UniswapV4Migrator migrator_) BaseHook(manager) {
        migrator = address(migrator_);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view override onlyMigrator(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        emit ModifyLiquidity(key, params);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        emit ModifyLiquidity(key, params);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Returns the hook permissions configuration
    /// @return permissions The hook permissions configuration
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
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
