// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { UniswapV4Migrator } from "./UniswapV4Migrator.sol";

/// @notice Thrown when the caller is not the Uniswap V4 Migrator
error OnlyMigrator();

/// @notice Thrown when the caller is not the contract deployer
error OnlyDeployer();

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

    /// @notice Hook that runs before pool initialization
    /// @param sender Address of the caller
    /// @param key Pool key containing pool parameters
    /// @param sqrtPriceX96 Initial sqrt price of the pool
    /// @return selector The hook selector
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal view override onlyMigrator(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Returns the hook permissions configuration
    /// @return permissions The hook permissions configuration
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
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
