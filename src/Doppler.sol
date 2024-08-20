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

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (
            block.timestamp < startingTime || (block.timestamp - startingTime) / epochLength == uint256(state.lastEpoch)
        ) {
            // TODO: consider whether there's any logic we wanna run regardless

            // TODO: Should there be a fee?
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        state.lastEpoch = uint40((block.timestamp - startingTime) / epochLength);

        uint256 totalTokensSold_ = state.totalTokensSold;
        uint256 expectedAmountSold = getExpectedAmountSold();

        // TODO: Should there be a fee?
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

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

    function getExpectedAmountSold() internal view returns (uint256) {
        return ((block.timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * numTokensToSell / 1e18;
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
