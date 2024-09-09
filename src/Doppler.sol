// TODO: Add license
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

// this library was not audited but is the same as v3
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // TODO: consider if we can use smaller uints
    struct State {
        uint40 lastEpoch; // last updated epoch (1-indexed)
        // TODO: consider whether this should be signed
        int24 tickAccumulator; // accumulator to modify the bonding curve
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
    int24 immutable gamma; // 1.0001 ** (gamma) = max single block increase
    bool immutable isToken0; // whether token0 is the token being sold (true) or token1 (false)

    constructor(
        IPoolManager _poolManager,
        uint256 _numTokensToSell,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        int24 _gamma,
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
        // TODO: gamma can be a int24 since its at most (type(int24).max - type(int24).min)
        // it is at minimum 1 tick spacing
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    // TODO: consider reverting or returning if after end time
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
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

        _rebalance(key);

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
        // TODO: account for fees
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

    function _rebalance(PoolKey calldata key) internal {
        // We increment by 1 to 1-index the epoch
        uint256 currentEpoch = (block.timestamp - startingTime) / epochLength + 1;
        uint24 epochsPassed = uint24(currentEpoch - uint256(state.lastEpoch));

        state.lastEpoch = uint40(currentEpoch);

        uint256 totalTokensSold_ = state.totalTokensSold;
        uint256 expectedAmountSold = _getExpectedAmountSold();
        // TODO: consider whether net sold should be divided by epochsPassed to get per epoch amount
        //       i think probably makes sense to divide by epochsPassed then multiply the delta later like we're doing now
        uint256 netSold = totalTokensSold_ - state.totalTokensSoldLastEpoch;

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        // get current state
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // accumulatorDelta must be int24 (since its in tickSpace)
        int24 accumulatorDelta;
        int24 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            // TODO: consider whether we actually wanna multiply by epochsPassed here
            // accumulatorDelta = int24(_getMaxTickDeltaPerEpoch() * uint24(epochsPassed));
            // temp: to simplify this down we just use maxdelta
            accumulatorDelta = int24(_getMaxTickDeltaPerEpoch());
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else if (totalTokensSold_ <= expectedAmountSold) {
            // TODO: consider whether we actually wanna multiply by epochsPassed here
            // temp: to simplify this down we just use maxdelta
            // accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed)
            //     * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
            // TODO: very dummy to cast these as i24 but whatever, will fix later
            accumulatorDelta = int24(_getMaxTickDeltaPerEpoch() * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18);
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else {
            // current starting tick
            int24 tau_t = startingTick + state.tickAccumulator;

            // TODO: check for overflow
            // this is the expected that we are currently at
            int24 expectedTick = tau_t + int24(_getGammaElasped());

            // how far are we above the expected tick?
            // has to be >=0 (could be 0 if rounded down)
            // casted to 256 for compatability
            accumulatorDelta = currentTick - expectedTick;

            newAccumulator = state.tickAccumulator + accumulatorDelta;
        }

        if (accumulatorDelta != 0) {
            // save the new accumulator
            state.tickAccumulator = newAccumulator;

            // overriding current tick - may need to undo this later
            currentTick = currentTick + newAccumulator;

            // we are rounding down - may be good to check if we should
            // round up if the token is token1
            // this places the tick on a tick spacing boundary
            currentTick = (currentTick / key.tickSpacing) * key.tickSpacing;
        }

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(newAccumulator);

        // --- Position Calculations Time
        uint256 soldAmt = state.totalTokensSold;
        uint256 protocolsProceeds = state.totalProceeds;

        // TODO: could avoid these calculation if currentTick is unchanged
        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(currentTick);

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // mathematically, we can do both of these 2 calcs in 1 step
        // however, it requires sqrtPrice * sqrtPrice, which can overflow (uint160 * uint160) = uint320 - uint160
        // im not entirely sure how to deal w/ it if it does
        uint128 liquidity;
        uint256 requiredProceeds;
        if (isToken0) {
            // TODO: check max liquidity per tick
            // an adversary could game the code to create too much liquidity in-range
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceNext, soldAmt);
            requiredProceeds = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceNext, liquidity, true);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceNext, sqrtPriceUpper, soldAmt);
            requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceNext, sqrtPriceUpper, liquidity, true);
        }

        // we check if we have enough tokens for the lower bonding curve
        // we do not SAD
        int24 lowerSlugTickUpper = tickLower;
        int24 lowerSlugTickLower = currentTick;
        uint128 lowerSlugLiquidity = liquidity;

        if (requiredProceeds > protocolsProceeds) {
            // you are about to see some "artistry"
            if (isToken0) {
                // TODO: check for overflow
                // TODO: we can likely clamp the x96 to x48 or something
                // then we don't need to multiply by at the next step

                // this is the regular (not sqrt) price
                // we want to move it back to sqrtPrice
                // TODO: unfuck this
                uint160 tgtPriceX96 = uint160(FullMath.mulDiv(protocolsProceeds, FixedPoint96.Q96, soldAmt));

                // check against TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE
                lowerSlugTickUpper = 2 * TickMath.getTickAtSqrtPrice(uint160(tgtPriceX96));
                lowerSlugTickLower = lowerSlugTickUpper - key.tickSpacing;

                liquidity = LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(lowerSlugTickLower), TickMath.getSqrtPriceAtTick(lowerSlugTickUpper), soldAmt);
            } else {
                // TODO: unfuck this
                uint160 tgtPriceX96 = uint160(FullMath.mulDiv(soldAmt, FixedPoint96.Q96, protocolsProceeds));

                lowerSlugTickLower = 2 * TickMath.getTickAtSqrtPrice(tgtPriceX96);
                lowerSlugTickUpper = lowerSlugTickLower + key.tickSpacing;
            }

            // TODO: calculate liquidity here
        }

        // lower slug calculated

        // TODO: Swap to intended tick
        // TODO: Remove in range liquidity
        // TODO: Flip a flag to prevent this swap from hitting beforeSwap
    }

    function _getTicksBasedOnState(int24 accumulator) internal view returns (int24, int24) {
        int24 lower = startingTick + accumulator;
        int24 upper = (lower + startingTick > endingTick) ? gamma : -(gamma);

        return (lower, upper);
    }

    function _getGammaElasped() internal view returns (int256) {
        return int256(((int256(block.timestamp) - int256(startingTime)) * 1e18 / (int256(endingTime) - int256(startingTime))) * int256(gamma) / 1e18);
    }

    // TODO: consider whether it's safe to always round down
    function _getExpectedAmountSold() internal view returns (uint256) {
        return ((block.timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * numTokensToSell / 1e18;
    }

    // TODO: consider whether it's safe to always round down
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) * epochLength) / 1e18;
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
