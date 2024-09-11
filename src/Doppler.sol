// TODO: Add license
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";

contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

    // TODO: consider if we can use smaller uints
    struct State {
        uint40 lastEpoch; // last updated epoch (1-indexed)
        int24 tickAccumulator; // accumulator to modify the bonding curve
        uint256 totalTokensSold; // total tokens sold
        uint256 totalProceeds; // total amount earned from selling tokens (numeraire)
        uint256 totalTokensSoldLastEpoch; // total tokens sold at the time of the last epoch
    }

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    // TODO: consider whether these need to be public
    State public state;
    mapping(bytes32 salt => Position) public positions;

    uint256 immutable numTokensToSell; // total amount of tokens to be sold
    uint256 immutable startingTime; // sale start time
    uint256 immutable endingTime; // sale end time
    int24 immutable startingTick; // dutch auction starting tick
    int24 immutable endingTick; // dutch auction ending tick
    uint256 immutable epochLength; // length of each epoch (seconds)
    // TODO: consider whether this should be signed
    // TODO: should this actually be "max single epoch increase"?
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
        if (isToken0) {
            int128 amount0 = swapDelta.amount0();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount0 >= 0
                ? state.totalTokensSold += uint256(uint128(amount0))
                : state.totalTokensSold -= uint256(uint128(-amount0));

            int128 amount1 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. positive amount means tokens were bought
            amount1 >= 0
                ? state.totalProceeds -= uint256(uint128(amount1))
                : state.totalProceeds += uint256(uint128(-amount1));
        } else {
            int128 amount1 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. negative amount means tokens were sold
            amount1 >= 0
                ? state.totalTokensSold += uint256(uint128(amount1))
                : state.totalTokensSold -= uint256(uint128(-amount1));

            int128 amount0 = swapDelta.amount1();
            // TODO: ensure this is the correct direction, i.e. positive amount means tokens were bought
            amount0 >= 0
                ? state.totalProceeds -= uint256(uint128(amount0))
                : state.totalProceeds += uint256(uint128(-amount0));
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
        uint256 currentEpoch = _getCurrentEpoch();
        uint256 epochsPassed = currentEpoch - uint256(state.lastEpoch);

        state.lastEpoch = uint40(currentEpoch);

        // Cache state vars to avoid multiple SLOADs
        uint256 totalTokensSold_ = state.totalTokensSold;
        uint256 totalProceeds_ = state.totalProceeds;

        // TODO: consider if this should be the expected amount sold at the start of the current epoch or at the current time
        // i think logically it makes sense to use the current time to get the most accurate rebalance
        uint256 expectedAmountSold = _getExpectedAmountSold(block.timestamp);
        // TODO: consider whether net sold should be divided by epochsPassed to get per epoch amount
        //       i think probably makes sense to divide by epochsPassed then multiply the delta later like we're doing now
        uint256 netSold = totalTokensSold_ - state.totalTokensSoldLastEpoch;

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        // get current state
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int256 accumulatorDelta;
        int256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            // TODO: consider whether we actually wanna multiply by epochsPassed here
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed) / 1e18;
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed) / 1e18
                * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
        } else {
            int24 tauTick = startingTick + state.tickAccumulator;
            int24 expectedTick;
            // TODO: Overflow possible?
            //       May be worth bounding to a maximum int24.max/min
            // TODO: Consider whether this is the correct direction
            //       Assumes that higher tick for token0 implies higher price
            isToken0
                ? expectedTick = tauTick + int24(_getElapsedGamma())
                : expectedTick = tauTick - int24(_getElapsedGamma());
            accumulatorDelta = int256(currentTick - expectedTick);
        }

        if (accumulatorDelta != 0) {
            newAccumulator = state.tickAccumulator + accumulatorDelta;
            state.tickAccumulator = int24(newAccumulator);

            // TODO: Consider whether it's ok to overwrite currentTick
            if (isToken0) {
                currentTick = ((currentTick + int24(accumulatorDelta)) / key.tickSpacing) * key.tickSpacing;
            } else {
                // TODO: Consider whether this rounds up as expected
                // Round up to support inverse direction
                currentTick =
                    ((currentTick + int24(accumulatorDelta) + key.tickSpacing - 1) / key.tickSpacing) * key.tickSpacing;
            }
        }

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(int24(newAccumulator));

        // TODO: Consider what's redundant below if currentTick is unchanged

        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity;
        uint256 requiredProceeds;
        if (totalTokensSold_ != 0) {
            if (isToken0) {
                // TODO: Check max liquidity per tick
                //       Should we spread liquidity across multiple ticks if necessary?
                liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceNext, totalTokensSold_);
                // TODO: Should we be rounding up here?
                requiredProceeds = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceNext, liquidity, true);
            } else {
                liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceNext, sqrtPriceUpper, totalTokensSold_);
                // TODO: Should we be rounding up here?
                requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceNext, sqrtPriceUpper, liquidity, true);
            }
        }

        int24 lowerSlugTickUpper = tickLower;
        int24 lowerSlugTickLower = currentTick;
        uint128 lowerSlugLiquidity = liquidity;

        // If we do not have enough proceeds to the full lower slug,
        // we switch to a single tick range at the target price
        if (requiredProceeds > totalProceeds_) {
            if (isToken0) {
                // Q96 Target price (not sqrtPrice)
                uint160 targetPriceX96 = uint160(FullMath.mulDiv(totalProceeds_, FixedPoint96.Q96, totalTokensSold_));

                // TODO: Consider whether this can revert due to InvalidSqrtPrice check
                // We multiply the tick of the regular price by 2 to get the tick of the sqrtPrice
                lowerSlugTickUpper = 2 * TickMath.getTickAtSqrtPrice(targetPriceX96);
                // TODO: Check max liquidity per tick
                //       Should we spread liquidity across multiple ticks if necessary?
                lowerSlugTickLower = lowerSlugTickUpper - key.tickSpacing;

                lowerSlugLiquidity = LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(lowerSlugTickLower),
                    TickMath.getSqrtPriceAtTick(lowerSlugTickUpper),
                    totalProceeds_
                );
            } else {
                // Q96 Target price (not sqrtPrice)
                uint160 targetPriceX96 = uint160(FullMath.mulDiv(totalTokensSold_, FixedPoint96.Q96, totalProceeds_));

                // TODO: Consider whether this can revert due to InvalidSqrtPrice check
                // We multiply the tick of the regular price by 2 to get the tick of the sqrtPrice
                lowerSlugTickUpper = 2 * TickMath.getTickAtSqrtPrice(targetPriceX96);
                // TODO: Check max liquidity per tick
                //       Should we spread liquidity across multiple ticks if necessary?
                // TODO: Consider whether lower and upper values should be swapped
                lowerSlugTickLower = lowerSlugTickUpper + key.tickSpacing;

                lowerSlugLiquidity = LiquidityAmounts.getLiquidityForAmount0(
                    TickMath.getSqrtPriceAtTick(lowerSlugTickLower),
                    TickMath.getSqrtPriceAtTick(lowerSlugTickUpper),
                    totalProceeds_
                );
            }
        }


        uint256 nextEpochTime = (_getCurrentEpoch() + 1) * epochLength + startingTime; // compute end time of current epoch
        uint256 percentElapsedAtNextEpoch = _getNormalizedTimeElapsed(nextEpochTime); // percent time elapsed at end of epoch 
        uint256 expectedSoldAtNextEpoch = (totalTokensSold_ * 1e18 / _getExpectedAmountSold(nextEpochTime)); // compute percent of tokens sold by next epoch
        int256 tokensSoldDelta = int256(percentElapsedAtNextEpoch) - int256(expectedSoldAtNextEpoch); // compute if we've sold more or less tokens than expected by next epoch

        int24 upperBoundTickLower;
        int24 upperBoundTickUpper;
        uint128 upperBoundLiquidity;

        if (tokensSoldDelta > 0) {
            uint256 tokens_to_lp = (uint256(tokensSoldDelta) * numTokensToSell) / 1e18;

            int256 upperSlugAccumulatorDelta = int256(_getGammaShare(nextEpochTime) * gamma / 1e18);
            int24 tick_t1 = currentTick + int24(upperSlugAccumulatorDelta);

            uint160 upperSlugAbovePrice = TickMath.getSqrtPriceAtTick(tick_t1);
            uint160 upperSlugBelowPrice = sqrtPriceNext;

            if (isToken0) {
                upperBoundTickLower = tick_t1;
                upperBoundTickUpper = currentTick;
                if (upperSlugAbovePrice < upperSlugBelowPrice) {
                    (upperBoundTickLower, upperBoundTickUpper) = (currentTick, tick_t1);
                    (upperSlugAbovePrice, upperSlugBelowPrice) = (upperSlugBelowPrice, upperSlugAbovePrice);
                }
                upperBoundLiquidity =
                    LiquidityAmounts.getLiquidityForAmount0(upperSlugBelowPrice, upperSlugAbovePrice, tokens_to_lp);
            } else {
                upperBoundTickLower = currentTick;
                upperBoundTickUpper = tick_t1;
                if (upperSlugAbovePrice > upperSlugBelowPrice) {
                    (upperBoundTickLower, upperBoundTickUpper) = (tick_t1, currentTick);
                    (upperSlugAbovePrice, upperSlugBelowPrice) = (upperSlugBelowPrice, upperSlugAbovePrice);
                }
                upperBoundLiquidity =
                    LiquidityAmounts.getLiquidityForAmount1(upperSlugBelowPrice, upperSlugAbovePrice, tokens_to_lp);
            }

            // TODO: Add liquidity using upperBoundTickLower, upperBoundTickUpper, and upperBoundLiquidity
        }

        // TODO: Swap to intended tick
        // TODO: Remove in range liquidity
        // TODO: Flip a flag to prevent this swap from hitting beforeSwap

        // TODO: If we're not actually modifying liquidity, skip below logic
        // TODO: Consider whether we need slippage protection
        // TODO: Consider whether we should later just adjust all positions in a single unlock callback

        // Get old position liquidity
        Position memory position = positions[LOWER_SLUG_SALT];

        // Execute lock - providing old and new position
        poolManager.unlock(abi.encode(position, Position({
            tickLower: lowerSlugTickLower,
            tickUpper: lowerSlugTickUpper,
            liquidity: lowerSlugLiquidity
        }), key));
        
        // Store new position ticks and liquidity
        positions[LOWER_SLUG_SALT] = Position({
            tickLower: lowerSlugTickLower,
            tickUpper: lowerSlugTickUpper,
            liquidity: lowerSlugLiquidity
        });
    }

    function _getCurrentEpoch() internal view returns (uint256) {
        return (block.timestamp - startingTime) / epochLength + 1;
    }

    function _getNormalizedTimeElapsed(uint256 timestamp) internal view returns (uint256) {
        if (timestamp > endingTime) {
            timestamp = endingTime;
        }
        return ((timestamp - startingTime) * 1e18) / (endingTime - startingTime);
    }

    function _getGammaShare(uint256 timestamp) internal view returns (uint256) {
        uint256 normalizedTimeElapsed = _getNormalizedTimeElapsed(timestamp);
        uint256 normalizedTimeElapsedPrev = _getNormalizedTimeElapsed(block.timestamp);
        return normalizedTimeElapsed - normalizedTimeElapsedPrev;
    }

    // TODO: consider whether it's safe to always round down
    function _getExpectedAmountSold(uint256 timestamp) internal view returns (uint256) {
        return ((timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * numTokensToSell / 1e18;
    }

    // Returns 18 decimal fixed point value
    // TODO: consider whether it's safe to always round down
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) * epochLength);
    }

    function _getElapsedGamma() internal view returns (int256) {
        return int256(((block.timestamp - startingTime) * 1e18 / (endingTime - startingTime)) * (gamma) / 1e18);
    }

    // TODO: Consider whether overflow is reasonably possible
    //       I think some validation logic will be necessary
    //       Maybe we just need to bound to int24.max/min
    function _getTicksBasedOnState(int24 accumulator) internal view returns (int24 lower, int24 upper) {
        lower = startingTick + accumulator;
        // TODO: Consider whether this is the correct direction
        upper = lower + (startingTick > endingTick ? int24(int256(gamma)) : -int24(int256(gamma)));
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

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (Position memory prevPosition, Position memory newPosition, PoolKey memory key) = abi.decode(data, (Position, Position, PoolKey));

        if (prevPosition.liquidity != 0) {
            // Remove all liquidity from old position
            // TODO: Consider whether fees are relevant
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
                tickLower: prevPosition.tickLower,
                tickUpper: prevPosition.tickUpper,
                liquidityDelta: -int128(prevPosition.liquidity),
                salt: LOWER_SLUG_SALT
            }), "");

            int256 delta0 = delta.amount0();
            int256 delta1 = delta.amount1();

            if (delta0 > 0) {
                poolManager.take(key.currency0, address(this), uint256(delta0));
            }

            if (delta1 > 0) {
                poolManager.take(key.currency1, address(this), uint256(delta1));
            }
        }

        if (newPosition.liquidity != 0) {
            // Add liquidity to new position
            // TODO: Consider whether fees are relevant
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
                tickLower: newPosition.tickLower,
                tickUpper: newPosition.tickUpper,
                liquidityDelta: int128(newPosition.liquidity),
                salt: LOWER_SLUG_SALT
            }), "");

            int256 delta0 = delta.amount0();
            int256 delta1 = delta.amount1();

            if (delta0 < 0) {
                key.currency0.transfer(address(poolManager), uint256(-delta0));
            }

            if (delta1 < 0) {
                key.currency1.transfer(address(poolManager), uint256(-delta1));
            }

            poolManager.settle();
        }
    }
}

error Unauthorized();
