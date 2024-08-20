// TODO: Add license
pragma solidity 0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";

contract Doppler is BaseHook {
    // TODO: consider if we can use smaller uints
    struct State {
        uint40 lastEpoch; // last updated epoch
        uint256 tickAccumulator; // accumulator to modify the bonding curve
        uint256 totalTokensSold; // total tokens sold
        uint256 totalProceeds; // total amount earned from selling tokens
        uint256 totalTokensSoldLastEpoch; // total tokens sold at the time of the last epoch
    }

    // TODO: consider whether this needs to be public
    State public state;

    uint256 immutable numTokensToSell; // total amount of tokens to be sold
    uint256 immutable startingTime; // sale start time
    uint256 immutable endingTime; // sale end time
    int24 immutable startingTick; // dutch auction starting tick
    int24 immutable endingTick; // dutch auction ending tick
    uint256 immutable epochLength; // length of each epoch (seconds)
    uint256 immutable gamma; // 1.0001 ** (gamma) = max single block increase
    bool immutable isToken0; // whether token0 is the token being sold (true) or token1 (false)

    constructor(
        IPoolManager _poolManager,
        uint256 _numTokensToSell,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        uint256 _gamma,
        bool _isToken0
    ) BaseHook(_poolManager) {
        numTokensToSell = _numTokensToSell;
        startingTime = _startingTime;
        endingTime = _endingTime;
        startingTick = _startingTick;
        endingTick = _endingTick;
        epochLength = _epochLength;
        gamma = _gamma;
        isToken0 = _isToken0;
    }

    // TODO: Add authorization logic
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 currentEpoch = (block.timestamp - startingTime) / epochLength;
        uint256 epochsPassed = currentEpoch - uint256(state.lastEpoch);
        if (
            block.timestamp < startingTime || epochsPassed == 0
        ) {
            // TODO: consider whether there's any logic we wanna run regardless

            // TODO: Should there be a fee?
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        state.lastEpoch = uint40(currentEpoch);

        uint256 totalTokensSold_ = state.totalTokensSold;
        uint256 expectedAmountSold = getExpectedAmountSold();
        // TODO: consider whether net sold should be divided by epochsPassed to get per epoch amount
        //       i think probably makes sense to divide by epochsPassed then multiply the delta later like we're doing now
        uint256 netSold = totalTokensSold_ - state.totalTokensSoldLastEpoch;
        
        state.totalTokensSoldLastEpoch = totalTokensSold_;

        uint256 accumulatorDelta;
        uint256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            // TODO: consider whether we actually wanna multiply by epochsPassed here
            accumulatorDelta = getMaxTickDeltaPerEpoch() * epochsPassed;
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = getMaxTickDeltaPerEpoch() * epochsPassed * (1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        }
        // TODO: What if totalTokensSold_ > expectedAmountSold?

        if (accumulatorDelta != 0) {
            state.tickAccumulator = newAccumulator;
        }

        // TODO: Should there be a fee?
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // TODO: Add authorization logic
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta swapDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        if (isToken0) {
            int128 amount = swapDelta.amount0();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount >= 0 ? state.totalTokensSold -= uint256(uint128(amount)) : state.totalTokensSold += uint256(uint128(-amount));
        } else {
            int128 amount = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount >= 0 ? state.totalTokensSold -= uint256(uint128(amount)) : state.totalTokensSold += uint256(uint128(-amount));
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // TODO: consider whether it's safe to always round down
    function getExpectedAmountSold() internal view returns (uint256) {
        return ((block.timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * numTokensToSell / 1e18;
    }

    // TODO: consider whether it's safe to always round down
    function getMaxTickDeltaPerEpoch() internal view returns (uint256) {
        return uint256(uint24(endingTick - startingTick)) * 1e18 / (endingTime - startingTime) * epochLength / 1e18;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
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
