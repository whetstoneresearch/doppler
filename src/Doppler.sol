// TODO: Add license
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, add, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";

contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

    // TODO: consider if we can use smaller uints
    struct State {
        uint40 lastEpoch; // last updated epoch (1-indexed)
        int256 tickAccumulator; // accumulator to modify the bonding curve
        uint256 totalTokensSold; // total tokens sold
        uint256 totalProceeds; // total amount earned from selling tokens (numeraire)
        uint256 totalTokensSoldLastEpoch; // total tokens sold at the time of the last epoch
    }

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        // TODO: Consider whether we need larger salt in case of multiple discovery slugs
        uint8 salt;
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
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        // TODO: Consider if we should use a struct or not, I like it because we can avoid passing the wrong data
        poolManager.unlock(abi.encode(CallbackData({key: key, sender: sender, tick: tick})));
        return BaseHook.afterInitialize.selector;
    }

    // TODO: consider reverting or returning if after end time
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (block.timestamp < startingTime) revert BeforeStartTime();
        if (_getCurrentEpoch() <= uint256(state.lastEpoch)) {
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

            int128 amount0 = swapDelta.amount0();
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

    struct SlugData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
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
        int256 netSold = int256(totalTokensSold_) - int256(state.totalTokensSoldLastEpoch);

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        // get current state
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int256 accumulatorDelta;
        int256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed);
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed)
                * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
        } else {
            int24 tauTick = startingTick + int24(state.tickAccumulator / 1e18);
            int24 expectedTick;
            // TODO: Overflow possible?
            //       May be worth bounding to a maximum int24.max/min
            // TODO: Consider whether this is the correct direction
            //       Assumes that higher tick for token0 implies higher price
            isToken0
                ? expectedTick = tauTick + int24(_getElapsedGamma())
                : expectedTick = tauTick - int24(_getElapsedGamma());
            // TODO: Should this be expectedTick - currentTick?
            accumulatorDelta = int256(currentTick - expectedTick) * 1e18;
        }

        if (accumulatorDelta != 0) {
            newAccumulator = state.tickAccumulator + accumulatorDelta;
            state.tickAccumulator = newAccumulator;
        }

        // TODO: Do we need to accumulate this difference over time to ensure it gets applied later?
        //       e.g. if accumulatorDelta is 4e18 for two epochs in a row, should we bump up by a tickSpacing
        //       after the second epoch, or only adjust on significant epochs?
        //       Maybe this is only necessary for the oversold case anyway?
        accumulatorDelta /= 1e18;

        // TODO: Consider whether it's ok to overwrite currentTick
        currentTick = _alignComputedTickWithTickSpacing(currentTick + int24(accumulatorDelta), key.tickSpacing);

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(int24(newAccumulator / 1e18), key.tickSpacing);

        // It's possible that these are equal
        // If we try to add liquidity in this range though, we revert with a divide by zero
        // Thus we have to create a gap between the two
        if (currentTick == tickLower) {
            // TODO: Consider whether direction is accurate
            if (isToken0) {
                tickLower -= key.tickSpacing;
            } else {
                tickLower += key.tickSpacing;
            }
        }

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
                // TODO: Check max liquidity per tick
                //       Should we spread liquidity across multiple ticks if necessary?
                liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceNext, totalTokensSold_);
                // TODO: Should we be rounding up here?
                requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceLower, sqrtPriceNext, liquidity, true);
            }
        }

        // Get existing positions
        Position[] memory prevPositions = new Position[](3);
        prevPositions[0] = positions[LOWER_SLUG_SALT];
        prevPositions[1] = positions[UPPER_SLUG_SALT];
        prevPositions[2] = positions[DISCOVERY_SLUG_SALT];
        BalanceDelta tokensRemoved = _clearPositions(prevPositions, key);

        uint256 numeraireAvailable =
            isToken0 ? uint256(uint128(tokensRemoved.amount1())) : uint256(uint128(tokensRemoved.amount0()));

        SlugData memory lowerSlug = _computeLowerSlugData(
            key, requiredProceeds, numeraireAvailable, totalTokensSold_, sqrtPriceLower, sqrtPriceNext
        );
        SlugData memory upperSlug = _computeUpperSlugData(key, totalTokensSold_, currentTick);
        SlugData memory priceDiscoverySlug = _computePriceDiscoverySlugData(key, upperSlug, tickUpper);
        // TODO: If we're not actually modifying liquidity, skip below logic
        // TODO: Consider whether we need slippage protection

        // Get new positions
        Position[] memory newPositions = new Position[](3);
        newPositions[0] = Position({
            tickLower: lowerSlug.tickLower,
            tickUpper: lowerSlug.tickUpper,
            liquidity: lowerSlug.liquidity,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        newPositions[1] = Position({
            tickLower: upperSlug.tickLower,
            tickUpper: upperSlug.tickUpper,
            liquidity: upperSlug.liquidity,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });
        newPositions[2] = Position({
            tickLower: priceDiscoverySlug.tickLower,
            tickUpper: priceDiscoverySlug.tickUpper,
            liquidity: priceDiscoverySlug.liquidity,
            salt: uint8(uint256(DISCOVERY_SLUG_SALT))
        });

        // Update positions and swap if necessary
        _update(newPositions, sqrtPriceX96, sqrtPriceNext, key);

        // Store new position ticks and liquidity
        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];
        positions[DISCOVERY_SLUG_SALT] = newPositions[2];
    }

    function _getEpochEndWithOffset(uint256 offset) internal view returns (uint256) {
        uint256 epochEnd = (_getCurrentEpoch() + offset) * epochLength + startingTime;
        if (epochEnd > endingTime) {
            epochEnd = endingTime;
        }
        return epochEnd;
    }

    function _getCurrentEpoch() internal view returns (uint256) {
        if (block.timestamp < startingTime) return 1;
        return (block.timestamp - startingTime) / epochLength + 1;
    }

    function _getNormalizedTimeElapsed(uint256 timestamp) internal view returns (uint256) {
        return (timestamp - startingTime) * 1e18 / (endingTime - startingTime);
    }

    function _getGammaShare() internal view returns (int256) {
        return int256(epochLength * 1e18 / (endingTime - startingTime));
    }

    // TODO: consider whether it's safe to always round down
    function _getExpectedAmountSold(uint256 timestamp) internal view returns (uint256) {
        return _getNormalizedTimeElapsed(timestamp) * numTokensToSell / 1e18;
    }

    // Returns 18 decimal fixed point value
    // TODO: consider whether it's safe to always round down
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) / epochLength);
    }

    function _getElapsedGamma() internal view returns (int256) {
        return int256(_getNormalizedTimeElapsed(block.timestamp)) * int256(gamma) / 1e18;
    }

    function _alignComputedTickWithTickSpacing(int24 tick, int24 tickSpacing) internal view returns (int24) {
        if (isToken0) {
            return (tick / tickSpacing) * tickSpacing;
        } else {
            return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
        }
    }

    // TODO: Consider whether overflow is reasonably possible
    //       I think some validation logic will be necessary
    //       Maybe we just need to bound to int24.max/min
    // Returns a multiple of tickSpacing
    function _getTicksBasedOnState(int24 accumulator, int24 tickSpacing)
        internal
        view
        returns (int24 lower, int24 upper)
    {
        // TODO: Consider whether this is the correct direction
        if (isToken0) {
            lower = startingTick + (accumulator / tickSpacing * tickSpacing);
            upper = (lower + gamma) / tickSpacing * tickSpacing;
        } else {
            // Round up to support inverse direction
            lower = startingTick + (accumulator + tickSpacing - 1 / tickSpacing * tickSpacing);
            upper = (lower - gamma) + tickSpacing - 1 / tickSpacing * tickSpacing;
        }
    }

    function _computeLowerSlugData(
        PoolKey memory key,
        uint256 requiredProceeds,
        uint256 totalProceeds_,
        uint256 totalTokensSold_,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceNext
    ) internal view returns (SlugData memory slug) {
        // If we do not have enough proceeds to the full lower slug,
        // we switch to a single tick range at the target price
        if (requiredProceeds > totalProceeds_) {
            uint160 targetPriceX96;
            if (isToken0) {
                // Q96 Target price (not sqrtPrice)
                targetPriceX96 = _computeTargetPriceX96(totalProceeds_, totalTokensSold_);
            } else {
                targetPriceX96 = _computeTargetPriceX96(totalTokensSold_, totalProceeds_);
            }
            uint160 priceLower;
            uint160 priceUpper;
            // TODO: Consider whether this can revert due to InvalidSqrtPrice check
            // We multiply the tick of the regular price by 2 to get the tick of the sqrtPrice
            int24 tickA = 2 * TickMath.getTickAtSqrtPrice(targetPriceX96);
            int24 tickB = isToken0 ? tickA - key.tickSpacing : tickA + key.tickSpacing;
            (slug.tickLower, slug.tickUpper, priceLower, priceUpper) = _sortTicks(tickA, tickB);
            slug.liquidity = _computeLiquidity(!isToken0, priceLower, priceUpper, totalProceeds_);
        } else {
            slug.tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLower);
            slug.tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceNext);
            slug.liquidity = _computeLiquidity(!isToken0, sqrtPriceLower, sqrtPriceNext, totalProceeds_);
        }
    }

    function _computeUpperSlugData(PoolKey memory key, uint256 totalTokensSold_, int24 currentTick)
        internal
        view
        returns (SlugData memory slug)
    {
        uint256 epochEndTime = _getEpochEndWithOffset(0); // compute end time of current epoch
        int256 tokensSoldDelta = int256(_getExpectedAmountSold(epochEndTime)) - int256(totalTokensSold_); // compute if we've sold more or less tokens than expected by next epoch

        uint160 priceUpper;
        uint160 priceLower;
        uint256 tokensToLp;
        if (tokensSoldDelta > 0) {
            tokensToLp = uint256(tokensSoldDelta);
            int24 computedDelta = int24(_getGammaShare() * gamma / 1e18);
            int24 accumulatorDelta = computedDelta > 0 ? computedDelta : key.tickSpacing;
            int24 tickA = currentTick;
            int24 tickB = _alignComputedTickWithTickSpacing(
                isToken0 ? tickA + accumulatorDelta : tickA - accumulatorDelta, key.tickSpacing
            );

            (slug.tickLower, slug.tickUpper, priceLower, priceUpper) = _sortTicks(tickA, tickB);
        } else {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
        }

        if (priceLower != priceUpper) {
            slug.liquidity = _computeLiquidity(isToken0, priceLower, priceUpper, tokensToLp);
        } else {
            slug.liquidity = 0;
        }
    }

    function _computePriceDiscoverySlugData(PoolKey memory key, SlugData memory upperSlug, int24 tickUpper)
        internal
        view
        returns (SlugData memory slug)
    {
        uint256 epochEndTime = _getEpochEndWithOffset(0); // compute end time of current epoch
        uint256 nextEpochEndTime = _getEpochEndWithOffset(1); // compute end time two epochs from now

        if (nextEpochEndTime != epochEndTime) {
            uint256 epochT1toT2Delta =
                _getNormalizedTimeElapsed(nextEpochEndTime) - _getNormalizedTimeElapsed(epochEndTime);

            if (epochT1toT2Delta > 0) {
                uint256 tokensToLp = (uint256(epochT1toT2Delta) * numTokensToSell) / 1e18;
                uint160 priceUpper;
                uint160 priceLower;
                int24 tickA = isToken0 ? upperSlug.tickUpper : tickUpper;
                int24 tickB;
                if (isToken0) {
                    tickB = tickUpper == upperSlug.tickUpper ? tickUpper + key.tickSpacing : tickUpper;
                } else {
                    tickB = tickUpper == upperSlug.tickUpper ? tickUpper - key.tickSpacing : upperSlug.tickUpper;
                }

                (slug.tickLower, slug.tickUpper, priceLower, priceUpper) = _sortTicks(tickA, tickB);
                slug.liquidity = _computeLiquidity(isToken0, priceLower, priceUpper, tokensToLp);
            }
        }
    }

    function _computeTargetPriceX96(uint256 num, uint256 denom) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(num, FixedPoint96.Q96, denom));
    }

    function _computeLiquidity(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        // TODO: Consider a better option
        // We decrement the amount by 1 to avoid rounding errors
        amount = amount != 0 ? amount - 1 : amount;

        if (forToken0) {
            return LiquidityAmounts.getLiquidityForAmount0(lowerPrice, upperPrice, amount);
        } else {
            return LiquidityAmounts.getLiquidityForAmount1(lowerPrice, upperPrice, amount);
        }
    }

    function _sortTicks(int24 tickA, int24 tickB)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper, uint160 priceLower, uint160 priceUpper)
    {
        uint160 priceA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 priceB = TickMath.getSqrtPriceAtTick(tickB);

        if (priceA < priceB) {
            (tickLower, tickUpper) = (tickA, tickB);
            (priceLower, priceUpper) = (priceA, priceB);
        } else {
            (tickLower, tickUpper) = (tickB, tickA);
            (priceLower, priceUpper) = (priceB, priceA);
        }
    }

    function _clearPositions(Position[] memory lastEpochPositions, PoolKey memory key)
        internal
        returns (BalanceDelta deltas)
    {
        for (uint256 i; i < lastEpochPositions.length; ++i) {
            if (lastEpochPositions[i].liquidity != 0) {
                // TODO: consider what to do with feeDeltas
                (BalanceDelta positionDeltas, BalanceDelta feeDeltas) = poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: lastEpochPositions[i].tickLower,
                        tickUpper: lastEpochPositions[i].tickUpper,
                        liquidityDelta: -int128(lastEpochPositions[i].liquidity),
                        salt: bytes32(uint256(lastEpochPositions[i].salt))
                    }),
                    ""
                );
                deltas = deltas + positionDeltas;
            }
        }
    }

    function _update(Position[] memory newPositions, uint160 currentPrice, uint160 swapPrice, PoolKey memory key)
        internal
    {
        if (swapPrice != currentPrice) {
            // We swap to the target price
            // Since there's no liquidity, we swap 0 amounts
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: swapPrice < currentPrice,
                    amountSpecified: 1, // We need a non-zero amount to pass checks
                    sqrtPriceLimitX96: swapPrice
                }),
                ""
            );
        }

        for (uint256 i; i < newPositions.length; ++i) {
            if (newPositions[i].liquidity != 0) {
                // Add liquidity to new position
                // TODO: Consider whether fees are relevant
                poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: newPositions[i].tickLower,
                        tickUpper: newPositions[i].tickUpper,
                        liquidityDelta: int128(newPositions[i].liquidity),
                        salt: bytes32(uint256(newPositions[i].salt))
                    }),
                    ""
                );
            }
        }

        int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
        int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);

        if (currency0Delta > 0) {
            poolManager.take(key.currency0, address(this), uint256(currency0Delta));
        }

        if (currency1Delta > 0) {
            poolManager.take(key.currency1, address(this), uint256(currency1Delta));
        }

        if (currency0Delta < 0) {
            poolManager.sync(key.currency0);
            key.currency0.transfer(address(poolManager), uint256(-currency0Delta));
        }

        if (currency1Delta < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(-currency1Delta));
        }

        poolManager.settle();
    }

    struct CallbackData {
        PoolKey key;
        address sender;
        int24 tick;
    }

    // @dev This callback is only used to add the initial liquidity when the pool is created
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        (PoolKey memory key,, int24 tick) = (callbackData.key, callbackData.sender, callbackData.tick);

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(int24(0), key.tickSpacing);

        SlugData memory upperSlug = _computeUpperSlugData(key, 0, tick);
        SlugData memory priceDiscoverySlug = _computePriceDiscoverySlugData(key, upperSlug, tickUpper);


        BalanceDelta finalDelta;

        {
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: upperSlug.tickLower,
                    tickUpper: upperSlug.tickUpper,
                    liquidityDelta: int128(upperSlug.liquidity),
                    salt: UPPER_SLUG_SALT
                }),
                ""
            );
            finalDelta = add(finalDelta, callerDelta);
        }

        {
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: priceDiscoverySlug.tickLower,
                    tickUpper: priceDiscoverySlug.tickUpper,
                    liquidityDelta: int128(priceDiscoverySlug.liquidity),
                    salt: DISCOVERY_SLUG_SALT
                }),
                ""
            );
            finalDelta = add(finalDelta, callerDelta);
        }

        if (isToken0) {
            poolManager.sync(key.currency0);
            key.currency0.transfer(address(poolManager), uint256(int256(finalDelta.amount0())));
        } else {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(int256(finalDelta.amount1())));
        }

        Position[] memory newPositions = new Position[](3);
        // TODO: should we do this? or is it ok to just not deal with the lower slug at all at this stage?
        newPositions[0] = Position({
            tickLower: 0,
            tickUpper: 0,
            liquidity: 0,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        newPositions[1] = Position({
            tickLower: upperSlug.tickLower,
            tickUpper: upperSlug.tickUpper,
            liquidity: upperSlug.liquidity,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });
        newPositions[2] = Position({
            tickLower: priceDiscoverySlug.tickLower,
            tickUpper: priceDiscoverySlug.tickUpper,
            liquidity: priceDiscoverySlug.liquidity,
            salt: uint8(uint256(DISCOVERY_SLUG_SALT))
        });

        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];
        positions[DISCOVERY_SLUG_SALT] = newPositions[2];


        poolManager.settle();

        return new bytes(0);
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
error BeforeStartTime();
