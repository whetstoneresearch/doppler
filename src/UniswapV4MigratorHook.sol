pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/// @notice Thrown when the caller is not the Uniswap V4 Migrator
error OnlyMigrator();

/**
 * @title Uniswap V4 Migrator Hook
 * @author Whetstone Research
 * @notice Hook for the Uniswap V4 Migrator to restrict pool initialization of a
 * v4 pool to the Uniswap V4 Migrator
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4MigratorHook is BaseHook {
    /// @notice Address of the Uniswap V4 Migrator
    address public immutable migrator;

    /// @notice Modifier to ensure the caller is the Uniswap V4 Migrator
    modifier onlyMigrator() {
        if (msg.sender != migrator) revert OnlyMigrator();
        _;
    }

    /// @notice Address of the Uniswap V4 Migrator
    constructor(IPoolManager manager, address migrator_) BaseHook(manager) {
        migrator = migrator_;
    }

    function _beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) internal view override onlyMigrator returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
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
