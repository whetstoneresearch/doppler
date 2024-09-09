// TODO: Add license
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";

contract Doppler is BaseHook {
    // TODO: consider if we can use smaller uints
    struct State {
        uint40 lastEpoch; // last updated epoch (1-indexed)
        // TODO: consider whether this should be signed
        int256 tickAccumulator; // accumulator to modify the bonding curve
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
    // TODO: consider whether this should be signed
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

        // TODO: consider enforcing that parameters are consistent with token direction
        // TODO: consider enforcing that startingTick and endingTick are valid
        // TODO: consider enforcing startingTime < endingTime
        // TODO: consider enforcing that epochLength is a factor of endingTime - startingTime
        // TODO: consider enforcing that min and max gamma
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    // TODO: consider reverting or returning if after end time
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (
            block.timestamp < startingTime
                || ((block.timestamp - startingTime) / epochLength + 1) <= uint256(state.lastEpoch)
        ) {
            // TODO: consider whether there's any logic we wanna run regardless

            // TODO: Should there be a fee?
            // TODO: Consider whether we should revert instead since swaps should not be possible
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _rebalance();

        // TODO: Should there be a fee?
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (isToken0) {
            int128 amount0 = swapDelta.amount0();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount0 >= 0
                ? state.totalTokensSold -= uint256(uint128(amount0))
                : state.totalTokensSold += uint256(uint128(-amount0));

            int128 amount1 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. positive amount means tokens were bought
            amount1 >= 0
                ? state.totalProceeds += uint256(uint128(amount1))
                : state.totalProceeds -= uint256(uint128(-amount1));
        } else {
            int128 amount1 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount1 >= 0
                ? state.totalTokensSold -= uint256(uint128(amount1))
                : state.totalTokensSold += uint256(uint128(-amount1));

            int128 amount0 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. positive amount means tokens were bought
            amount0 >= 0
                ? state.totalProceeds += uint256(uint128(amount0))
                : state.totalProceeds -= uint256(uint128(-amount0));
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address _caller,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (_caller != address(this)) revert Unauthorized();

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _rebalance() internal {
        // We increment by 1 to 1-index the epoch
        uint256 currentEpoch = (block.timestamp - startingTime) / epochLength + 1;
        uint256 epochsPassed = currentEpoch - uint256(state.lastEpoch);

        state.lastEpoch = uint40(currentEpoch);

        uint256 totalTokensSold_ = state.totalTokensSold;
        uint256 expectedAmountSold = _getExpectedAmountSold();
        // TODO: consider whether net sold should be divided by epochsPassed to get per epoch amount
        //       i think probably makes sense to divide by epochsPassed then multiply the delta later like we're doing now
        uint256 netSold = totalTokensSold_ - state.totalTokensSoldLastEpoch;

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        int256 accumulatorDelta;
        int256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            // TODO: consider whether we actually wanna multiply by epochsPassed here
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed) / 1e18;
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed) / 1e18
                * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        }
        // TODO: What if totalTokensSold_ > expectedAmountSold?

        if (accumulatorDelta != 0) {
            state.tickAccumulator = newAccumulator;
        }

        // TODO: Swap to intended tick
        // TODO: Remove in range liquidity
        // TODO: Flip a flag to prevent this swap from hitting beforeSwap
    }

    // TODO: consider whether it's safe to always round down
    function _getExpectedAmountSold() internal view returns (uint256) {
        return ((block.timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * numTokensToSell / 1e18;
    }

    // TODO: consider whether it's safe to always round down
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) * epochLength);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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

error Unauthorized();
