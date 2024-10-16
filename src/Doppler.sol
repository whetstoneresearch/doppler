// TODO: Add license
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, add, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta, add, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

struct SlugData {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

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

// TODO: consider what a good tick spacing cieling is
int24 constant MAX_TICK_SPACING = 30;

// TODO: consider what a good max would be
uint256 constant MAX_PRICE_DISCOVERY_SLUGS = 10;

contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

    // TODO: consider if we can use smaller uints
    // TODO: consider whether these need to be public
    State public state;
    mapping(bytes32 salt => Position) public positions;

    uint256 immutable numTokensToSell; // total amount of tokens to be sold
    uint256 immutable startingTime; // sale start time
    uint256 immutable endingTime; // sale end time
    int24 immutable startingTick; // dutch auction starting tick
    int24 immutable endingTick; // dutch auction ending tick
    uint256 immutable epochLength; // length of each epoch (seconds)
    int24 immutable gamma; // 1.0001 ** (gamma) = max single epoch change
    bool immutable isToken0; // whether token0 is the token being sold (true) or token1 (false)
    uint256 immutable numPDSlugs; // number of price discovery slugs

    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        uint256 _numTokensToSell,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        int24 _gamma,
        bool _isToken0,
        uint256 _numPDSlugs
    ) BaseHook(_poolManager) {
        /* Tick checks */
        // Starting tick must be greater than ending tick if isToken0
        // Ending tick must be greater than starting tick if isToken1
        if (_isToken0 && _startingTick <= _endingTick) revert InvalidTickRange();
        if (!_isToken0 && _startingTick >= _endingTick) revert InvalidTickRange();
        // Enforce maximum tick spacing
        if (_poolKey.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();

        /* Time checks */
        uint256 timeDelta = _endingTime - _startingTime;
        // Starting time must be less than ending time
        if (_startingTime >= _endingTime) revert InvalidTimeRange();
        // Inconsistent gamma, epochs must be long enough such that the upperSlug is at least 1 tick
        // TODO: Consider whether this should check if the left side is less than tickSpacing
        if (int256(_epochLength * 1e18 / timeDelta) * _gamma / 1e18 == 0) revert InvalidGamma();
        // _endingTime - startingTime must be divisible by epochLength
        if (timeDelta % _epochLength != 0) revert InvalidEpochLength();

        /* Gamma checks */
        // Enforce that the total tick delta is divisible by the total number of epochs
        int24 totalTickDelta = _isToken0 ? _startingTick - _endingTick : _endingTick - _startingTick;
        int256 totalEpochs = int256((_endingTime - _startingTime) / _epochLength);
        // DA worst case is starting tick - ending tick
        if (_gamma * totalEpochs != totalTickDelta) revert InvalidGamma();
        // Enforce that gamma is divisible by tick spacing
        if (_gamma % _poolKey.tickSpacing != 0) revert InvalidGamma();

        /* Num price discovery slug checks */
        if (_numPDSlugs == 0) revert InvalidNumPDSlugs();
        if (_numPDSlugs > MAX_PRICE_DISCOVERY_SLUGS) revert InvalidNumPDSlugs();

        numTokensToSell = _numTokensToSell;
        startingTime = _startingTime;
        endingTime = _endingTime;
        startingTick = _startingTick;
        endingTick = _endingTick;
        epochLength = _epochLength;
        gamma = _gamma;
        isToken0 = _isToken0;
        numPDSlugs = _numPDSlugs;
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // TODO: Consider if we should use a struct or not, I like it because we can avoid passing the wrong data
        poolManager.unlock(abi.encode(CallbackData({key: key, sender: sender, tick: tick})));
        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (block.timestamp < startingTime || block.timestamp > endingTime) revert InvalidTime();
        if (_getCurrentEpoch() <= uint256(state.lastEpoch)) {
            // TODO: Should there be a fee?
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _rebalance(key);

        // TODO: Should there be a fee?
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Get current tick
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        // Get the lower tick of the lower slug
        int24 tickLower = positions[LOWER_SLUG_SALT].tickLower;

        if (isToken0) {
            if (currentTick < tickLower) revert SwapBelowRange();

            int128 amount0 = swapDelta.amount0();
            amount0 >= 0
                ? state.totalTokensSold += uint256(uint128(amount0))
                : state.totalTokensSold -= uint256(uint128(-amount0));

            int128 amount1 = swapDelta.amount1();
            amount1 >= 0
                ? state.totalProceeds -= uint256(uint128(amount1))
                : state.totalProceeds += uint256(uint128(-amount1));
        } else {
            if (currentTick > tickLower) revert SwapBelowRange();

            int128 amount1 = swapDelta.amount1();
            amount1 >= 0
                ? state.totalTokensSold += uint256(uint128(amount1))
                : state.totalTokensSold -= uint256(uint128(-amount1));

            int128 amount0 = swapDelta.amount0();
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

        // Cache state var to avoid multiple SLOADs
        uint256 totalTokensSold_ = state.totalTokensSold;

        // TODO: consider if this should be the expected amount sold at the start of the current epoch or at the current time
        // i think logically it makes sense to use the current time to get the most accurate rebalance
        uint256 expectedAmountSold = _getExpectedAmountSoldWithEpochOffset(0);
        int256 netSold = int256(totalTokensSold_) - int256(state.totalTokensSoldLastEpoch);

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        // get current state
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        Position memory upSlug = positions[UPPER_SLUG_SALT];

        int256 accumulatorDelta;
        int256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed);
        } else if (totalTokensSold_ <= expectedAmountSold) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch()
                * int256(1e18 - (totalTokensSold_ * 1e18 / expectedAmountSold)) / 1e18;
        } else {
            int24 tauTick = startingTick + int24(state.tickAccumulator / 1e18);
            Position memory pdSlug = positions[DISCOVERY_SLUG_SALT];

            int24 computedRange = int24(_getGammaShare() * gamma / 1e18);
            int24 upperSlugRange = computedRange > key.tickSpacing ? computedRange : key.tickSpacing;

            // The expectedTick is where the upperSlug.tickUpper is/would be placed
            // The upperTick is not always placed so we have to compute it's placement in case it's not
            // This depends on the invariant that upperSlug.tickLower == currentTick at the time of rebalancing
            int24 expectedTick = _alignComputedTickWithTickSpacing(
                isToken0 ? upSlug.tickLower + upperSlugRange : upSlug.tickLower - upperSlugRange, key.tickSpacing
            );

            // We bound the currentTick by the top of the curve (tauTick + gamma)
            // This is necessary because there is no liquidity above the curve and we need to
            // ensure that the accumulatorDelta is just based on meaningful (in range) ticks
            if (isToken0) {
                currentTick = currentTick > (tauTick + gamma) ? (tauTick + gamma) : currentTick;
            } else {
                currentTick = currentTick < (tauTick - gamma) ? (tauTick - gamma) : currentTick;
            }

            accumulatorDelta = int256(currentTick - expectedTick) * 1e18;
        }

        newAccumulator = state.tickAccumulator + accumulatorDelta;
        // Only sstore if there is a nonzero delta
        if (accumulatorDelta != 0) {
            state.tickAccumulator = newAccumulator;
        }

        // TODO: Do we need to accumulate this difference over time to ensure it gets applied later?
        //       e.g. if accumulatorDelta is 4e18 for two epochs in a row, should we bump up by a tickSpacing
        //       after the second epoch, or only adjust on significant epochs?
        //       Maybe this is only necessary for the oversold case anyway?
        accumulatorDelta /= 1e18;

        currentTick = _alignComputedTickWithTickSpacing(upSlug.tickLower + int24(accumulatorDelta), key.tickSpacing);

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(newAccumulator, key.tickSpacing);

        // It's possible that these are equal
        // If we try to add liquidity in this range though, we revert with a divide by zero
        // Thus we have to create a gap between the two
        if (currentTick == tickLower) {
            // TODO: May be worth bounding to a maximum int24.max/min to prevent over/underflow
            if (isToken0) {
                tickLower -= key.tickSpacing;
            } else {
                tickLower += key.tickSpacing;
            }
        }

        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 requiredProceeds =
            totalTokensSold_ != 0 ? _computeRequiredProceeds(sqrtPriceLower, sqrtPriceUpper, totalTokensSold_) : 0;

        // Get existing positions
        Position[] memory prevPositions = new Position[](2 + numPDSlugs);
        prevPositions[0] = positions[LOWER_SLUG_SALT];
        prevPositions[1] = positions[UPPER_SLUG_SALT];
        for (uint256 i; i < numPDSlugs; ++i) {
            prevPositions[2 + i] = positions[bytes32(uint256(3 + i))];
        }

        BalanceDelta tokensRemoved = _clearPositions(prevPositions, key);

        uint256 numeraireAvailable;
        uint256 assetAvailable;
        if (isToken0) {
            numeraireAvailable = uint256(uint128(tokensRemoved.amount1()));
            assetAvailable = uint256(uint128(tokensRemoved.amount0())) + key.currency0.balanceOfSelf();
        } else {
            numeraireAvailable = uint256(uint128(tokensRemoved.amount0()));
            assetAvailable = uint256(uint128(tokensRemoved.amount1())) + key.currency1.balanceOfSelf();
        }

        SlugData memory lowerSlug =
            _computeLowerSlugData(key, requiredProceeds, numeraireAvailable, totalTokensSold_, tickLower, currentTick);
        SlugData memory upperSlug = _computeUpperSlugData(key, totalTokensSold_, currentTick, assetAvailable);
        SlugData[] memory priceDiscoverySlugs = _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, assetAvailable);
        // TODO: If we're not actually modifying liquidity, skip below logic
        // TODO: Consider whether we need slippage protection

        // Get new positions
        Position[] memory newPositions = new Position[](2 + numPDSlugs);
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
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            newPositions[2 + i] = Position({
                tickLower: priceDiscoverySlugs[i].tickLower,
                tickUpper: priceDiscoverySlugs[i].tickUpper,
                liquidity: priceDiscoverySlugs[i].liquidity,
                salt: uint8(3 + i)
            });
        }

        // Update positions and swap if necessary
        _update(newPositions, sqrtPriceX96, sqrtPriceNext, key);

        // Store new position ticks and liquidity
        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];
        for (uint256 i; i < numPDSlugs; ++i) {
            if (i >= priceDiscoverySlugs.length) {
                // Clear the position from storage if it's not being placed
                delete positions[bytes32(uint256(3 + i))];
            } else {
                positions[bytes32(uint256(3 + i))] = newPositions[2 + i];
            }
        }
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
        return FullMath.mulDiv(timestamp - startingTime, 1e18, endingTime - startingTime);
    }

    function _getGammaShare() internal view returns (int256) {
        return int256(epochLength * 1e18 / (endingTime - startingTime));
    }

    // 0 == end of last epoch
    // 1 == end of current epoch 
    // n == end of nth epoch from current
    function _getExpectedAmountSoldWithEpochOffset(uint256 offset) internal view returns (uint256) {
        return FullMath.mulDiv(_getNormalizedTimeElapsed((_getCurrentEpoch() + offset - 1) * epochLength + startingTime), numTokensToSell, 1e18);
    }

    // Returns 18 decimal fixed point value
    // TODO: consider whether it's safe to always round down
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) / epochLength);
    }

    // TODO: Consider bounding to int24.max/min
    function _alignComputedTickWithTickSpacing(int24 tick, int24 tickSpacing) internal view returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return (tick / tickSpacing) * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return (tick / tickSpacing) * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }

    function _computeRequiredProceeds(uint160 sqrtPriceLower, uint160 sqrtPriceUpper, uint256 amount)
        internal
        view
        returns (uint256 requiredProceeds)
    {
        uint128 liquidity;
        if (isToken0) {
            // TODO: Check max liquidity per tick
            //       Should we spread liquidity across multiple ticks if necessary?
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount);
            // TODO: Should we be rounding up here?
            requiredProceeds = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        } else {
            // TODO: Check max liquidity per tick
            //       Should we spread liquidity across multiple ticks if necessary?
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, amount);
            // TODO: Should we be rounding up here?
            requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        }
    }

    // TODO: Consider whether overflow is reasonably possible
    //       I think some validation logic will be necessary
    //       Maybe we just need to bound to int24.max/min
    // Returns a multiple of tickSpacing
    function _getTicksBasedOnState(int256 accumulator, int24 tickSpacing)
        internal
        view
        returns (int24 lower, int24 upper)
    {
        int24 accumulatorDelta = int24(accumulator / 1e18);
        int24 adjustedTick = startingTick + accumulatorDelta;
        lower = _alignComputedTickWithTickSpacing(adjustedTick, tickSpacing);

        if (isToken0) {
            upper = lower + gamma;
        } else {
            upper = lower - gamma;
        }
    }

    function _computeLowerSlugData(
        PoolKey memory key,
        uint256 requiredProceeds,
        uint256 totalProceeds_,
        uint256 totalTokensSold_,
        int24 tickLower,
        int24 currentTick
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
            // TODO: Consider whether this can revert due to InvalidSqrtPrice check
            // TODO: Consider whether the target price should actually be tickUpper
            // We multiply the tick of the regular price by 2 to get the tick of the sqrtPrice
            // This should probably be + tickSpacing in the case of !isToken0
            slug.tickLower = _alignComputedTickWithTickSpacing(
                TickMath.getTickAtSqrtPrice(targetPriceX96) / 2, key.tickSpacing
            ) + (isToken0 ? -key.tickSpacing : key.tickSpacing);
            slug.tickUpper = isToken0 ? slug.tickLower + key.tickSpacing : slug.tickLower - key.tickSpacing;
            slug.liquidity = _computeLiquidity(
                !isToken0,
                TickMath.getSqrtPriceAtTick(slug.tickLower),
                TickMath.getSqrtPriceAtTick(slug.tickUpper),
                totalProceeds_
            );
        } else {
            slug.tickLower = tickLower;
            slug.tickUpper = currentTick;
            slug.liquidity = _computeLiquidity(
                !isToken0,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(currentTick),
                totalProceeds_
            );
        }

        // We make sure that the lower tick and upper tick are equal if no liquidity
        // else we don't properly enforce that swaps can't be made below the lower slug
        if (slug.liquidity == 0) {
            slug.tickLower = slug.tickUpper;
        }
    }

    function _computeUpperSlugData(
        PoolKey memory key,
        uint256 totalTokensSold_,
        int24 currentTick,
        uint256 assetAvailable
    ) internal view returns (SlugData memory slug) {
        int256 tokensSoldDelta = int256(_getExpectedAmountSoldWithEpochOffset(1)) - int256(totalTokensSold_); // compute if we've sold more or less tokens than expected by next epoch

        uint256 tokensToLp;
        if (tokensSoldDelta > 0) {
            tokensToLp = uint256(tokensSoldDelta) > assetAvailable ? assetAvailable : uint256(tokensSoldDelta);
            int24 computedDelta = int24(_getGammaShare() * gamma / 1e18);
            int24 accumulatorDelta = computedDelta > key.tickSpacing ? computedDelta : key.tickSpacing;
            slug.tickLower = currentTick;
            slug.tickUpper = _alignComputedTickWithTickSpacing(
                isToken0 ? slug.tickLower + accumulatorDelta : slug.tickLower - accumulatorDelta, key.tickSpacing
            );
        } else {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
        }

        if (slug.tickLower != slug.tickUpper) {
            slug.liquidity = _computeLiquidity(
                isToken0,
                TickMath.getSqrtPriceAtTick(slug.tickLower),
                TickMath.getSqrtPriceAtTick(slug.tickUpper),
                tokensToLp
            );
            assetAvailable -= tokensToLp;
        } else {
            slug.liquidity = 0;
        }
    }

    function _computePriceDiscoverySlugsData(
        PoolKey memory key,
        SlugData memory upperSlug,
        int24 tickUpper,
        uint256 assetAvailable
    ) internal view returns (SlugData[] memory) {
        SlugData[] memory slugs = new SlugData[](numPDSlugs);

        uint256 epochEndTime = _getEpochEndWithOffset(0); // compute end time of current epoch
        uint256 nextEpochEndTime = _getEpochEndWithOffset(1); // compute end time of next epoch

        // Return early if we're on the final epoch
        if (nextEpochEndTime == epochEndTime) {
            return slugs;
        }

        uint256 epochT1toT2Delta =
            _getNormalizedTimeElapsed(nextEpochEndTime) - _getNormalizedTimeElapsed(epochEndTime);
        
        uint256 tokensToLp = FullMath.mulDiv(epochT1toT2Delta, numTokensToSell, 1e18);
        tokensToLp = tokensToLp > assetAvailable ? assetAvailable : tokensToLp;

        int24 slugRangeDelta = (tickUpper - upperSlug.tickUpper) / int24(int256(numPDSlugs));

        for (uint256 i; i < numPDSlugs; ++i) {
            // If epoch [i] end time is equal to next epoch [i+1] end time, we've reached the end
            // and don't need to provide any more slugs
            if (_getEpochEndWithOffset(i) == _getEpochEndWithOffset(i + 1)) {
                break;
            }

            if (i == 0) {
                slugs[i].tickLower = upperSlug.tickUpper;
            } else {
                slugs[i].tickLower = slugs[i - 1].tickUpper;
            }
            // TODO: Bound by the type(int24).max/min
            slugs[i].tickUpper = _alignComputedTickWithTickSpacing(slugs[i].tickLower + slugRangeDelta, key.tickSpacing);
            
            // TODO: Ensure we don't compute liquidity for a 0 tick range
            slugs[i].liquidity = _computeLiquidity(
                isToken0,
                TickMath.getSqrtPriceAtTick(slugs[i].tickLower),
                TickMath.getSqrtPriceAtTick(slugs[i].tickUpper),
                // We reuse tokensToLp since it should be the same for all epochs
                // This is dependent on the invariant that (endingTime - startingTime) % epochLength == 0
                tokensToLp
            );
        }

        return slugs;
    }

    function _computeTargetPriceX96(uint256 num, uint256 denom) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(num, FixedPoint96.Q96, denom));
    }

    function _computeLiquidity(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        // TODO: This is probably not necessary anymore since we're bounding liquidity by
        //       the amount of tokens available to provide. Should still carefully consider
        //       whether this is necessary
        // We decrement the amount by 1 to avoid rounding errors
        amount = amount != 0 ? amount - 1 : amount;

        if (forToken0) {
            return LiquidityAmounts.getLiquidityForAmount0(lowerPrice, upperPrice, amount);
        } else {
            return LiquidityAmounts.getLiquidityForAmount1(lowerPrice, upperPrice, amount);
        }
    }

    function _clearPositions(Position[] memory lastEpochPositions, PoolKey memory key)
        internal
        returns (BalanceDelta deltas)
    {
        for (uint256 i; i < lastEpochPositions.length; ++i) {
            if (lastEpochPositions[i].liquidity != 0) {
                // TODO: consider what to do with feeDeltas (second return variable)
                (BalanceDelta positionDeltas,) = poolManager.modifyLiquidity(
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
                        tickLower: newPositions[i].tickLower < newPositions[i].tickUpper
                            ? newPositions[i].tickLower
                            : newPositions[i].tickUpper,
                        tickUpper: newPositions[i].tickUpper > newPositions[i].tickLower
                            ? newPositions[i].tickUpper
                            : newPositions[i].tickLower,
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

        (, int24 tickUpper) = _getTicksBasedOnState(int24(0), key.tickSpacing);

        SlugData memory upperSlug = _computeUpperSlugData(key, 0, tick, numTokensToSell);
        SlugData[] memory priceDiscoverySlugs = _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, numTokensToSell);

        BalanceDelta finalDelta;

        if (upperSlug.liquidity != 0) {
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

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (priceDiscoverySlugs[i].liquidity != 0) {
                (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: priceDiscoverySlugs[i].tickLower,
                        tickUpper: priceDiscoverySlugs[i].tickUpper,
                        liquidityDelta: int128(priceDiscoverySlugs[i].liquidity),
                        salt: bytes32(uint256(3 + i))
                    }),
                    ""
                );
                finalDelta = add(finalDelta, callerDelta);
            }
        }

        if (isToken0) {
            poolManager.sync(key.currency0);
            key.currency0.transfer(address(poolManager), uint256(int256(-finalDelta.amount0())));
        } else {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(int256(-finalDelta.amount1())));
        }

        Position[] memory newPositions = new Position[](2 + numPDSlugs);
        newPositions[0] =
            Position({tickLower: tick, tickUpper: tick, liquidity: 0, salt: uint8(uint256(LOWER_SLUG_SALT))});
        newPositions[1] = Position({
            tickLower: upperSlug.tickLower,
            tickUpper: upperSlug.tickUpper,
            liquidity: upperSlug.liquidity,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });

        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            newPositions[2 + i] = Position({
                tickLower: priceDiscoverySlugs[i].tickLower,
                tickUpper: priceDiscoverySlugs[i].tickUpper,
                liquidity: priceDiscoverySlugs[i].liquidity,
                salt: uint8(3 + i)
            });

            positions[bytes32(uint256(3 + i))] = newPositions[2 + i];
        }

        poolManager.settle();

        return new bytes(0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
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

error InvalidGamma();
error InvalidTimeRange();
error Unauthorized();
error BeforeStartTime();
error SwapBelowRange();
error InvalidTime();
error InvalidTickRange();
error InvalidTickSpacing();
error InvalidEpochLength();
error InvalidTickDelta();
error InvalidNumPDSlugs();
