// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { UniswapV4ScheduledMulticurveInitializer } from "src/UniswapV4ScheduledMulticurveInitializer.sol";
import { HookedMulticurveInitializer } from "src/HookedMulticurve.sol";
import { ITokenHook } from "src/interfaces/ITokenHook.sol";

/// @notice Thrown when a swap is attempted before the starting time
error CannotSwapBeforeStartingTime();

/**
 * @title Uniswap V4 Scheduled Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Scheduled Multicurve Initializer to restrict liquidity
 * addition in a Uniswap V4 pool and prevent swaps before a given starting time
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4ScheduledMulticurveInitializerHook is UniswapV4MulticurveInitializerHook, ITokenHook {
    /// @notice Starting time of each pool, stored as a unix timestamp
    mapping(PoolId poolId => uint256 startingTime) public startingTimeOf;

    mapping(PoolId poolId => address tokenHook) public getTokenHook;

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(
        IPoolManager manager,
        UniswapV4ScheduledMulticurveInitializer initializer
    ) UniswapV4MulticurveInitializerHook(manager, initializer) { }

    /**
     * @notice Sets the starting time for a given pool
     * @param poolKey Key of the pool
     * @param startingTime Timestamp at which trading can start, past times are set to current block timestamp
     */
    function setStartingTime(PoolKey memory poolKey, uint256 startingTime) external onlyInitializer(msg.sender) {
        startingTimeOf[poolKey.toId()] = startingTime <= block.timestamp ? block.timestamp : startingTime;
    }

    function pushTokenHook(
        address asset
    ) external {
        (,,, address migrationHook,,, PoolKey memory poolKey) = HookedMulticurveInitializer(initializer).getState(asset);

        getTokenHook[poolKey.toId()] = migrationHook;
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
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        require(block.timestamp >= startingTimeOf[key.toId()], CannotSwapBeforeStartingTime());

        address tokenHook = getTokenHook[key.toId()];

        // exec keeper actions
        if (tokenHook != address(0)) {
            ITokenHook(tokenHook).onSwap(abi.encode(key, msg.sender));
        }
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
