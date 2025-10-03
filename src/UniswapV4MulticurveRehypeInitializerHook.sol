// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { Position } from "src/types/Position.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { SwapMath } from "@v4-core/libraries/SwapMath.sol";

// goals
// - create an empty full range LP position given tickSpacing
// - save that position so that we can rehype it later
// - when a swap happens, we should dynamically update the fee, and do a self swap to get 50/50
// - when we get 50/50, we should add liquidity to the full range LP position
// - after all is said and done, we should update the fee back to its original value

/// @notice Thrown when the caller is not the Uniswap V4 Multicurve Initializer
error OnlyInitializer();

/**
 * @notice Emitted when liquidity is modified
 * @param key Key of the related pool
 * @param params Parameters of the liquidity modification
 */
event ModifyLiquidity(PoolKey key, IPoolManager.ModifyLiquidityParams params);

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

struct Fees {
    uint128 fees0;
    uint128 fees1;
}

uint256 constant MAX_SWAP_FEE = SwapMath.MAX_SWAP_FEE;

// TODO: factor in decimals haha 1e6 maybe for 18 decimals? idk haha
uint128 constant EPSILON = 1e6;

/**
 * @title Uniswap V4 Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by the Uniswap V4 Multicurve Initializer to restrict liquidity
 * addition in a Uniswap V4 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4MulticurveRehypeInitializerHook is BaseHook {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for *;

    /// @notice Address of the Uniswap V4 Multicurve Initializer contract
    address public immutable INITIALIZER;
    mapping(PoolId poolId => Position position) public getPosition;
    mapping(PoolId poolId => Fees fees) public getFees;

    /**
     *
     * @dev Modifier to ensure the caller is the Uniswap V4 Multicurve Initializer
     * @param sender Address of the caller
     */
    modifier onlyInitializer(
        address sender
    ) {
        if (sender != INITIALIZER) revert OnlyInitializer();
        _;
    }

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(IPoolManager manager, UniswapV4MulticurveInitializer initializer) BaseHook(manager) {
        INITIALIZER = address(initializer);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view override onlyInitializer(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
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

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        /// @param delta The amount owed to the caller (positive) or owed to the pool (negative)
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        //
        PoolId poolId = key.toId();

        Position memory position = getPosition[poolId];
        if (position.liquidity == 0) {
            // create the empty full range position
            (int24 minTick, int24 maxTick) = _getMinMaxTick(key);
            position = Position({ tickLower: minTick, tickUpper: maxTick, liquidity: 0, salt: bytes32(0) });
            getPosition[poolId] = position;
        }

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint24 swapFee = (params.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee())
            .calculateSwapFee(lpFee);

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // TODO: we're assuming that protocol fee is 0 here haha make sure we fix this later haha
        if (amount0 <= 0) {
            uint128 fees0 = uint128(FullMath.mulDiv(uint128(-amount0), swapFee, swapFee));
            getFees[poolId].fees0 += fees0;
        } else if (amount1 <= 0) {
            uint128 fees1 = uint128(FullMath.mulDiv(uint128(-amount1), swapFee, swapFee));
            getFees[poolId].fees1 += fees1;
        }

        if (getFees[poolId].fees0 >= EPSILON || getFees[poolId].fees1 >= EPSILON) {
            // binary search for the swap amount that will give us 50/50
        }
        emit Swap(sender, key, key.toId(), params, delta.amount0(), delta.amount1(), hookData);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Gets the min and max ticks for a given pool key
    function _getMinMaxTick(
        PoolKey memory key
    ) internal pure returns (int24 minTick, int24 maxTick) {
        maxTick = TickMath.MAX_TICK / key.tickSpacing * key.tickSpacing;
        minTick = (TickMath.MIN_TICK + key.tickSpacing - 1) / key.tickSpacing * key.tickSpacing;
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
            beforeSwap: false,
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
