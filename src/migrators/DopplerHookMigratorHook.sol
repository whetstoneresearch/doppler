// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import { ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { BaseHook } from "src/base/BaseHook.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";

interface IDopplerHookMigratorView {
    struct PoolState {
        address numeraire;
        PoolKey poolKey;
        address dopplerHook;
        bytes onGraduationCalldata;
        uint8 status;
    }

    function getAsset(PoolId poolId) external view returns (address);
    function getState(address asset) external view returns (PoolState memory);
    function isDopplerHookEnabled(address dopplerHook) external view returns (uint256);
}

/**
 * @notice Emitted when a Swap occurs
 * @param sender Address calling the PoolManager
 * @param poolKey Key of the related pool
 * @param poolId Id of the related pool
 * @param params Parameters of the swap
 * @param amount0 Balance denominated in token0
 * @param amount1 Balance denominated in token1
 * @param hookData Data passed to the hook
 */
event Swap(
    address indexed sender,
    PoolKey indexed poolKey,
    PoolId indexed poolId,
    IPoolManager.SwapParams params,
    int128 amount0,
    int128 amount1,
    bytes hookData
);

/// @notice Thrown when the caller is not the migrator
error OnlyMigrator();

/**
 * @title Doppler Hook Migrator Hook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Minimal hook used as the destination hooks address for migration pools.
 * All pool state is owned by the migrator.
 */
contract DopplerHookMigratorHook is ImmutableAirlock, BaseHook {
    using CurrencyLibrary for Currency;
    /// @notice Address of the migrator contract
    IDopplerHookMigratorView public immutable migrator;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 Pool Manager
     * @param migrator_ Address of the DopplerHookMigrator contract
     */
    constructor(address airlock_, IPoolManager poolManager_, address migrator_)
        ImmutableAirlock(airlock_)
        ImmutableState(poolManager_)
    {
        migrator = IDopplerHookMigratorView(migrator_);
    }

    receive() external payable { }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != address(migrator)) revert OnlyMigrator();
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Updates the dynamic LP fee for a pool
     * @dev Only callable by the migrator; PoolManager enforces hooks-only access.
     */
    function updateDynamicLPFee(PoolKey calldata poolKey, uint24 lpFee) external {
        if (msg.sender != address(migrator)) revert OnlyMigrator();
        PoolKey memory key = poolKey;
        key.hooks = IHooks(address(this));
        poolManager.updateDynamicLPFee(key, lpFee);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        address asset = migrator.getAsset(key.toId());
        IDopplerHookMigratorView.PoolState memory state = migrator.getState(asset);
        address dopplerHook = state.dopplerHook;

        int128 delta;

        if (dopplerHook != address(0) && migrator.isDopplerHookEnabled(dopplerHook) & ON_SWAP_FLAG != 0) {
            Currency feeCurrency;
            (feeCurrency, delta) = IDopplerHook(dopplerHook).onSwap(sender, key, params, balanceDelta, data);

            if (delta > 0) {
                poolManager.take(feeCurrency, address(this), uint128(delta));
                poolManager.sync(feeCurrency);

                if (feeCurrency.isAddressZero()) {
                    poolManager.settleFor{ value: uint128(delta) }(dopplerHook);
                } else {
                    feeCurrency.transfer(address(poolManager), uint128(delta));
                    poolManager.settleFor(dopplerHook);
                }
            }
        }

        emit Swap(sender, key, key.toId(), params, balanceDelta.amount0(), balanceDelta.amount1(), data);
        return (BaseHook.afterSwap.selector, delta);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
