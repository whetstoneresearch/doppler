// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { UniswapV4ScheduledMulticurveInitializer } from "src/UniswapV4ScheduledMulticurveInitializer.sol";
import { UniswapV4ScheduledMulticurveInitializerHook } from "src/UniswapV4ScheduledMulticurveInitializerHook.sol";

/// @notice Thrown when a swap is attempted by a non-approved sender
error SenderNotApproved();

/**
 * @title Uniswap V4 Swap Check Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Swap Check Multicurve Initializer to restrict swaps and prevent
 * them before a given starting time
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4SwapCheckMulticurveInitializerHook is UniswapV4ScheduledMulticurveInitializerHook {
    /// @notice Mapping of approved addresses that can perform swaps
    mapping(PoolId poolId => mapping(address sender => bool)) public isApproved;

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(
        IPoolManager manager,
        UniswapV4ScheduledMulticurveInitializer initializer
    ) UniswapV4ScheduledMulticurveInitializerHook(manager, initializer) { }

    function setApproved(
        PoolKey memory poolKey,
        address[] calldata senders
    ) external onlyInitializer(msg.sender) {
        PoolId poolId = poolKey.toId();

        for (uint256 i; i != senders.length;) {
            isApproved[poolId][senders[i]] = true;

            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        require(isApproved[key.toId()][sender], SenderNotApproved());
        return super._beforeSwap(sender, key, params, data);
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
