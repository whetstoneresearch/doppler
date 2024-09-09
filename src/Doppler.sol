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

    struct RebalanceState {
        uint256 currentEpoch;
        uint24 epochsPassed;
        uint256 totalTokensSold;
        uint256 totalProceeds;
        uint256 totalTokensSoldLastEpoch;
        uint256 expectedAmountSold;
        uint256 netSold;
        int24 accumulatorDelta;
        int24 newAccumulator;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceNext;
        uint160 sqrtPriceUpper;
    }

    function _rebalance(PoolKey calldata key) internal {
        RebalanceState memory rebalanceState;

        // We increment by 1 to 1-index the epoch
        rebalanceState.currentEpoch = (block.timestamp - startingTime) / epochLength + 1;
        rebalanceState.epochsPassed = uint24(rebalanceState.currentEpoch - uint256(state.lastEpoch));

        state.lastEpoch = uint40(rebalanceState.currentEpoch);

        rebalanceState.totalTokensSold = state.totalTokensSold;
        rebalanceState.expectedAmountSold = _getExpectedAmountSold();
        rebalanceState.netSold = rebalanceState.totalTokensSold - state.totalTokensSoldLastEpoch;

        // update total tokens in canonical state
        state.totalTokensSoldLastEpoch = rebalanceState.totalTokensSold;

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        (rebalanceState.accumulatorDelta, rebalanceState.newAccumulator) = _calculateAccumulatorDelta(
            rebalanceState.netSold, rebalanceState.totalTokensSold, rebalanceState.expectedAmountSold, rebalanceState.epochsPassed, currentTick
        );

        if (rebalanceState.accumulatorDelta != 0) {
            state.tickAccumulator = rebalanceState.newAccumulator;
            currentTick = (currentTick + rebalanceState.newAccumulator) / key.tickSpacing * key.tickSpacing;
        }

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(rebalanceState.newAccumulator);

        rebalanceState.sqrtPriceLower = TickMath.getSqrtPriceAtTick(currentTick);
        rebalanceState.sqrtPriceNext = TickMath.getSqrtPriceAtTick(tickLower);
        rebalanceState.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        (uint128 liquidity, uint256 requiredProceeds) = _calculateLiquidityAndProceeds(
            rebalanceState.sqrtPriceLower, rebalanceState.sqrtPriceNext, rebalanceState.sqrtPriceUpper, state.totalTokensSold 
        );

        (int24 lowerSlugTickUpper, int24 lowerSlugTickLower, uint128 lowerSlugLiquidity) = _calculateLowerSlug(
            requiredProceeds, state.totalProceeds, state.totalTokensSold, key, liquidity, currentTick, tickLower
        );

        // TODO: Swap to intended tick
        // TODO: Remove in range liquidity
        // TODO: Flip a flag to prevent this swap from hitting beforeSwap
    }

    function _calculateAccumulatorDelta(
        uint256 netSold,
        uint256 totalTokensSold_,
        uint256 expectedAmountSold,
        uint24 epochsPassed,
        int24 currentTick
    ) internal view returns (int24, int24) {
        int24 accumulatorDelta;
        int24 newAccumulator;

        if (netSold <= 0) {
            accumulatorDelta = int24(_getMaxTickDeltaPerEpoch() * int24(epochsPassed));
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = int24(
                _getMaxTickDeltaPerEpoch() * int24(epochsPassed) * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18
            );
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        } else {
            int24 tau_t = startingTick + state.tickAccumulator;
            int24 expectedTick = tau_t + int24(_getGammaElasped());
            accumulatorDelta = currentTick - expectedTick;
            newAccumulator = state.tickAccumulator + accumulatorDelta;
        }

        return (accumulatorDelta, newAccumulator);
    }

    function _calculateLiquidityAndProceeds(
        uint160 sqrtPriceLower,
        uint160 sqrtPriceNext,
        uint160 sqrtPriceUpper,
        uint256 soldAmt
    ) internal view returns (uint128, uint256) {
        uint128 liquidity;
        uint256 requiredProceeds;

        if (isToken0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceNext, soldAmt);
            requiredProceeds = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceNext, liquidity, true);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceNext, sqrtPriceUpper, soldAmt);
            requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceNext, sqrtPriceUpper, liquidity, true);
        }

        return (liquidity, requiredProceeds);
    }

    function _calculateLowerSlug(
        uint256 requiredProceeds,
        uint256 protocolsProceeds,
        uint256 soldAmt,
        PoolKey calldata key,
        uint128 liquidity,
        int24 currentTick,
        int24 tickLower
    ) internal view returns (int24, int24, uint128) {
        int24 lowerSlugTickUpper = tickLower;
        int24 lowerSlugTickLower = currentTick;
        uint128 lowerSlugLiquidity = liquidity;

        if (requiredProceeds > protocolsProceeds) {
            if (isToken0) {
                uint160 tgtPriceX96 = uint160(FullMath.mulDiv(protocolsProceeds, FixedPoint96.Q96, soldAmt));
                lowerSlugTickUpper = 2 * TickMath.getTickAtSqrtPrice(uint160(tgtPriceX96));
                lowerSlugTickLower = lowerSlugTickUpper - key.tickSpacing;
                lowerSlugLiquidity = LiquidityAmounts.getLiquidityForAmount0(
                    TickMath.getSqrtPriceAtTick(lowerSlugTickLower),
                    TickMath.getSqrtPriceAtTick(lowerSlugTickUpper),
                    soldAmt
                );
            } else {
                uint160 tgtPriceX96 = uint160(FullMath.mulDiv(soldAmt, FixedPoint96.Q96, protocolsProceeds));
                lowerSlugTickLower = 2 * TickMath.getTickAtSqrtPrice(tgtPriceX96);
                lowerSlugTickUpper = lowerSlugTickLower + key.tickSpacing;
            }
        }

        return (lowerSlugTickUpper, lowerSlugTickLower, lowerSlugLiquidity);
    }

    function _getTicksBasedOnState(int24 accumulator) internal view returns (int24, int24) {
        int24 lower = startingTick + accumulator;
        int24 upper = (lower + startingTick > endingTick) ? gamma : -(gamma);

        return (lower, upper);
    }

    function _getGammaElasped() internal view returns (int256) {
        return int256(
            ((int256(block.timestamp) - int256(startingTime)) * 1e18 / (int256(endingTime) - int256(startingTime)))
                * int256(gamma) / 1e18
        );
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
