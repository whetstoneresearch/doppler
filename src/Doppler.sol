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
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ProtocolFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/ProtocolFeeLibrary.sol";

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
    BalanceDelta feesAccrued; // fees accrued to the pool
}

struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

uint256 constant MAX_SWAP_FEE = 1e6;
int24 constant MAX_TICK_SPACING = 30;
uint256 constant MAX_PRICE_DISCOVERY_SLUGS = 10;

/// @title Doppler
/// @author kadenzipfel, kinrezC, clemlak, aadams, and Alexangelj
contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;

    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

    bool public insufficientProceeds; // triggers if the pool matures and minimumProceeds is not met
    bool public earlyExit; // triggers if the pool ever reaches or exceeds maximumProceeds

    State public state;
    mapping(bytes32 salt => Position) public positions;

    uint256 immutable numTokensToSell; // total amount of tokens to be sold
    uint256 immutable minimumProceeds; // minimum proceeds required to avoid refund phase
    uint256 immutable maximumProceeds; // proceeds amount that will trigger early exit condition
    uint256 immutable startingTime; // sale start time
    uint256 immutable endingTime; // sale end time
    int24 immutable startingTick; // dutch auction starting tick
    int24 immutable endingTick; // dutch auction ending tick
    uint256 immutable epochLength; // length of each epoch (seconds)
    int24 immutable gamma; // 1.0001 ** (gamma) = max single epoch change
    bool immutable isToken0; // whether token0 is the token being sold (true) or token1 (false)
    uint256 immutable numPDSlugs; // number of price discovery slugs

    uint256 immutable totalEpochs; // total number of epochs

    receive() external payable {}

    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        uint256 _numTokensToSell,
        uint256 _minimumProceeds,
        uint256 _maximumProceeds,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        int24 _gamma,
        bool _isToken0,
        uint256 _numPDSlugs
    ) BaseHook(_poolManager) {
        // Check that the current time is before the starting time
        if (block.timestamp > _startingTime) revert InvalidTime();
        /* Tick checks */
        // Starting tick must be greater than ending tick if isToken0
        // Ending tick must be greater than starting tick if isToken1
        if (_startingTick != _endingTick) {
            if (_isToken0 && _startingTick <= _endingTick) revert InvalidTickRange();
            if (!_isToken0 && _startingTick >= _endingTick) revert InvalidTickRange();
        }
        // Enforce maximum tick spacing
        if (_poolKey.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();

        /* Time checks */
        uint256 timeDelta = _endingTime - _startingTime;
        // Starting time must be less than ending time
        if (_startingTime >= _endingTime) revert InvalidTimeRange();
        // Inconsistent gamma, epochs must be long enough such that the upperSlug is at least 1 tick
        // TODO: Consider whether this should check if the left side is less than tickSpacing
        if (int256(FullMath.mulDiv(FullMath.mulDiv(_epochLength, 1e18, timeDelta), uint256(int256(_gamma)), 1e18)) == 0)
        {
            revert InvalidGamma();
        }
        // _endingTime - startingTime must be divisible by epochLength
        if (timeDelta % _epochLength != 0) revert InvalidEpochLength();

        /* Gamma checks */
        // Enforce that the total tick delta is divisible by the total number of epochs
        // Enforce that gamma is divisible by tick spacing
        if (_gamma % _poolKey.tickSpacing != 0) revert InvalidGamma();

        /* Num price discovery slug checks */
        if (_numPDSlugs == 0) revert InvalidNumPDSlugs();
        if (_numPDSlugs > MAX_PRICE_DISCOVERY_SLUGS) revert InvalidNumPDSlugs();

        // These can both be zero
        if (_minimumProceeds > _maximumProceeds) revert InvalidProceedLimits();

        totalEpochs = (_endingTime - _startingTime) / _epochLength;

        numTokensToSell = _numTokensToSell;
        minimumProceeds = _minimumProceeds;
        maximumProceeds = _maximumProceeds;
        startingTime = _startingTime;
        endingTime = _endingTime;
        startingTick = _startingTick;
        endingTick = _endingTick;
        epochLength = _epochLength;
        gamma = _gamma;
        isToken0 = _isToken0;
        numPDSlugs = _numPDSlugs;
    }

    /// @notice Called by poolManager following initialization, used to place initial liquidity slugs
    /// @param sender The address that called poolManager.initialize
    /// @param key The pool key
    /// @param tick The initial tick of the pool
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        poolManager.unlock(abi.encode(CallbackData({key: key, sender: sender, tick: tick})));
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Called by the poolManager immediately before a swap is executed
    ///         Triggers rebalancing logic in new epochs and handles early exit/insufficient proceeds outcomes
    /// @param key The pool key
    /// @param swapParams The parameters for swapping
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (earlyExit) revert MaximumProceedsReached();

        if (block.timestamp < startingTime) revert InvalidTime();

        // We can skip rebalancing if we're in an epoch that already had a rebalance
        if (_getCurrentEpoch() <= uint256(state.lastEpoch)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Only check proceeds if we're after maturity and we haven't already triggered insufficient proceeds
        if (block.timestamp >= endingTime && !insufficientProceeds) {
            // If we haven't raised the minimum proceeds, we allow for all asset tokens to be sold back into
            // the curve at the average clearing price
            if (state.totalProceeds < minimumProceeds) {
                insufficientProceeds = true;

                PoolId poolId = key.toId();
                (, int24 currentTick,,) = poolManager.getSlot0(poolId);

                Position[] memory prevPositions = new Position[](2 + numPDSlugs);
                prevPositions[0] = positions[LOWER_SLUG_SALT];
                prevPositions[1] = positions[UPPER_SLUG_SALT];
                for (uint256 i; i < numPDSlugs; ++i) {
                    prevPositions[2 + i] = positions[bytes32(uint256(3 + i))];
                }

                // Place all available numeraire in the lower slug at the average clearing price
                uint256 numeraireAvailable = isToken0
                    ? uint256(uint128(_clearPositions(prevPositions, key).amount1()))
                    : uint256(uint128(_clearPositions(prevPositions, key).amount0()));
                SlugData memory lowerSlug =
                    _computeLowerSlugInsufficientProceeds(key, numeraireAvailable, state.totalTokensSold);
                Position[] memory newPositions = new Position[](1);

                newPositions[0] = Position({
                    tickLower: lowerSlug.tickLower,
                    tickUpper: lowerSlug.tickUpper,
                    liquidity: lowerSlug.liquidity,
                    salt: uint8(uint256(LOWER_SLUG_SALT))
                });

                // Include tickSpacing so we're at least at a higher price than the lower slug upper tick
                uint160 sqrtPriceX96Next = TickMath.getSqrtPriceAtTick(
                    _alignComputedTickWithTickSpacing(lowerSlug.tickUpper, key.tickSpacing)
                        + (isToken0 ? key.tickSpacing : -key.tickSpacing)
                );

                uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
                _update(newPositions, sqrtPriceX96, sqrtPriceX96Next, key);
                positions[LOWER_SLUG_SALT] = newPositions[0];

                // Add 1 to numPDSlugs because we don't need to clear the lower slug
                // but we do need to clear the upper/pd slugs
                for (uint256 i; i < numPDSlugs + 1; ++i) {
                    delete positions[bytes32(uint256(2 + i))];
                }
            } else {
                revert InvalidSwapAfterMaturitySufficientProceeds();
            }
        }
        // If startTime < block.timestamp < endTime and !earlyExit and !insufficientProceeds, we rebalance
        if (!insufficientProceeds) {
            _rebalance(key);
        } else {
            // If we have insufficient proceeds, only allow swaps from asset -> numeraire
            if (isToken0) {
                if (swapParams.zeroForOne == false) {
                    revert InvalidSwapAfterMaturityInsufficientProceeds();
                }
            } else {
                if (swapParams.zeroForOne == true) {
                    revert InvalidSwapAfterMaturityInsufficientProceeds();
                }
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Called by the poolManager immediately after a swap is executed
    ///         Used to update totalTokensSold and totalProceeds with swap amounts, excluding fees
    ///         If we've exceeded the maximumProceeds, we trigger the early exit condition
    ///         We revert if the swap is below the range of the lower slug to prevent manipulation
    /// @param key The pool key
    /// @param swapDelta The balance delta of the address swapping
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Get current tick
        PoolId poolId = key.toId();
        (, int24 currentTick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        // Get the lower tick of the lower slug
        int24 tickLower = positions[LOWER_SLUG_SALT].tickLower;
        uint24 swapFee = uint16(protocolFee).calculateSwapFee(lpFee);

        if (isToken0) {
            if (currentTick < tickLower) revert SwapBelowRange();

            int128 amount0 = swapDelta.amount0();
            if (amount0 >= 0) {
                state.totalTokensSold += uint256(uint128(amount0));
            } else {
                uint256 tokensSoldLessFee =
                    FullMath.mulDiv(uint256(uint128(-amount0)), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalTokensSold -= tokensSoldLessFee;
            }

            int128 amount1 = swapDelta.amount1();
            if (amount1 >= 0) {
                state.totalProceeds -= uint256(uint128(amount1));
            } else {
                uint256 proceedsLessFee =
                    FullMath.mulDiv(uint256(uint128(-amount1)), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalProceeds += proceedsLessFee;
            }
        } else {
            if (currentTick > tickLower) revert SwapBelowRange();

            int128 amount1 = swapDelta.amount1();
            if (amount1 >= 0) {
                state.totalTokensSold += uint256(uint128(amount1));
            } else {
                uint256 tokensSoldLessFee =
                    FullMath.mulDiv(uint256(uint128(-amount1)), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalTokensSold -= tokensSoldLessFee;
            }

            int128 amount0 = swapDelta.amount0();
            if (amount0 >= 0) {
                state.totalProceeds -= uint256(uint128(amount0));
            } else {
                uint256 proceedsLessFee =
                    FullMath.mulDiv(uint256(uint128(-amount0)), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalProceeds += proceedsLessFee;
            }
        }

        // If we reach or exceed the maximumProceeds, we trigger the early exit condition
        if (state.totalProceeds >= maximumProceeds) {
            earlyExit = true;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Called by the poolManager immediately before liquidity is added
    ///         We revert if the caller is not this contract
    /// @param caller The address that called poolManager.modifyLiquidity
    function beforeAddLiquidity(
        address caller,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (caller != address(this)) revert Unauthorized();

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Executed before swaps in new epochs to rebalance the bonding curve
    ///         We adjust the bonding curve according to the amount tokens sold relative to the expected amount
    /// @param key The pool key
    function _rebalance(PoolKey calldata key) internal {
        // We increment by 1 to 1-index the epoch
        uint256 currentEpoch = _getCurrentEpoch();
        uint256 epochsPassed = currentEpoch - uint256(state.lastEpoch);

        state.lastEpoch = uint40(currentEpoch);

        // Cache state var to avoid multiple SLOADs
        uint256 totalTokensSold_ = state.totalTokensSold;

        // Get the expected amount sold and the net sold in the last epoch
        uint256 expectedAmountSold = _getExpectedAmountSoldWithEpochOffset(0);
        int256 netSold = int256(totalTokensSold_) - int256(state.totalTokensSoldLastEpoch);

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        Position memory upSlug = positions[UPPER_SLUG_SALT];

        int256 accumulatorDelta;
        int256 newAccumulator;
        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold <= 0) {
            accumulatorDelta = _getMaxTickDeltaPerEpoch() * int256(epochsPassed);
        } else if (totalTokensSold_ <= expectedAmountSold) {
            // Safe from overflow since we use 256 bits with a maximum value of (2**24-1) * 1e18
            accumulatorDelta = _getMaxTickDeltaPerEpoch()
                * int256(1e18 - FullMath.mulDiv(totalTokensSold_, 1e18, expectedAmountSold)) / 1e18;
        } else {
            int24 tauTick = startingTick + int24(state.tickAccumulator / 1e18);

            // Safe from overflow since the result is <= gamma which is an int24 already
            int24 computedRange = int24(_getGammaShare() * gamma / 1e18);
            int24 upperSlugRange = computedRange > key.tickSpacing ? computedRange : key.tickSpacing;

            // The expectedTick is where the upperSlug.tickUpper is/would be placed in the previous epoch
            // The upperTick is not always placed so we have to compute its placement in case it's not
            // This depends on the invariant that upperSlug.tickLower == currentTick at the time of rebalancing
            int24 expectedTick = _alignComputedTickWithTickSpacing(
                isToken0 ? upSlug.tickLower + upperSlugRange : upSlug.tickLower - upperSlugRange, key.tickSpacing
            );

            uint256 epochsRemaining = totalEpochs - currentEpoch;
            int24 liquidityBound = isToken0 ? tauTick + gamma : tauTick - gamma;
            liquidityBound = epochsRemaining < numPDSlugs
                ? positions[bytes32(uint256(3 + epochsRemaining))].tickUpper
                : liquidityBound;

            // We bound the currentTick by the top of the curve (tauTick + gamma)
            // This is necessary because there is no liquidity above the curve and we need to
            // ensure that the accumulatorDelta is just based on meaningful (in range) ticks
            if (isToken0) {
                currentTick = currentTick > liquidityBound ? liquidityBound : currentTick;
            } else {
                currentTick = currentTick < liquidityBound ? liquidityBound : currentTick;
            }

            accumulatorDelta = int256(currentTick - expectedTick) * 1e18;
        }

        newAccumulator = state.tickAccumulator + accumulatorDelta;
        // Only sstore if there is a nonzero delta
        if (accumulatorDelta != 0) {
            state.tickAccumulator = newAccumulator;
        }

        currentTick =
            _alignComputedTickWithTickSpacing(upSlug.tickLower + int24(accumulatorDelta / 1e18), key.tickSpacing);

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(newAccumulator, key.tickSpacing);

        // It's possible that these are equal
        // If we try to add liquidity in this range though, we revert with a divide by zero
        // Thus we have to create a gap between the two
        if (currentTick == tickLower) {
            if (isToken0) {
                tickLower -= key.tickSpacing;
            } else {
                tickLower += key.tickSpacing;
            }
        }

        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);

        uint256 requiredProceeds =
            totalTokensSold_ != 0 ? _computeRequiredProceeds(sqrtPriceLower, sqrtPriceNext, totalTokensSold_) : 0;

        // Get existing positions
        Position[] memory prevPositions = new Position[](2 + numPDSlugs);
        prevPositions[0] = positions[LOWER_SLUG_SALT];
        prevPositions[1] = positions[UPPER_SLUG_SALT];
        for (uint256 i; i < numPDSlugs; ++i) {
            prevPositions[2 + i] = positions[bytes32(uint256(3 + i))];
        }

        // Remove existing positions, track removed tokens
        BalanceDelta tokensRemoved = _clearPositions(prevPositions, key);

        uint256 numeraireAvailable;
        uint256 assetAvailable;
        if (isToken0) {
            numeraireAvailable = uint256(uint128(tokensRemoved.amount1()));
            assetAvailable = uint256(uint128(tokensRemoved.amount0())) + key.currency0.balanceOfSelf()
                - uint128(state.feesAccrued.amount0());
        } else {
            numeraireAvailable = uint256(uint128(tokensRemoved.amount0()));
            assetAvailable = uint256(uint128(tokensRemoved.amount1())) + key.currency1.balanceOfSelf()
                - uint128(state.feesAccrued.amount1());
        }

        // Compute new positions
        SlugData memory lowerSlug =
            _computeLowerSlugData(key, requiredProceeds, numeraireAvailable, totalTokensSold_, tickLower, currentTick);
        (SlugData memory upperSlug, uint256 assetRemaining) =
            _computeUpperSlugData(key, totalTokensSold_, currentTick, assetAvailable);
        SlugData[] memory priceDiscoverySlugs =
            _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, assetRemaining);

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

    /// @notice If offset == 0, retrieves the end time of the current epoch
    ///         If offset == n, retrieves the end time of the nth epoch from the current
    /// @param offset The offset from the current epoch
    function _getEpochEndWithOffset(uint256 offset) internal view returns (uint256) {
        uint256 epochEnd = (_getCurrentEpoch() + offset) * epochLength + startingTime;
        if (epochEnd > endingTime) {
            epochEnd = endingTime;
        }
        return epochEnd;
    }

    /// @notice Retrieves the current epoch
    function _getCurrentEpoch() internal view returns (uint256) {
        if (block.timestamp < startingTime) return 1;
        return (block.timestamp - startingTime) / epochLength + 1;
    }

    /// @notice Retrieves the elapsed time since the start of the sale, normalized to 1e18
    /// @param timestamp The timestamp to retrieve for
    function _getNormalizedTimeElapsed(uint256 timestamp) internal view returns (uint256) {
        return FullMath.mulDiv(timestamp - startingTime, 1e18, endingTime - startingTime);
    }

    /// @notice Computes the gamma share for a single epoch, used as a measure for the upper slug range
    function _getGammaShare() internal view returns (int256) {
        return int256(FullMath.mulDiv(epochLength, 1e18, (endingTime - startingTime)));
    }

    /// @notice If offset == 0, retrieves the expected amount sold by the end of the last epoch
    ///         If offset == 1, retrieves the expected amount sold by the end of the current epoch
    ///         If offset == n, retrieves the expected amount sold by the end of the nth epoch from the current
    /// @param offset The epoch offset to retrieve for
    function _getExpectedAmountSoldWithEpochOffset(uint256 offset) internal view returns (uint256) {
        return FullMath.mulDiv(
            _getNormalizedTimeElapsed((_getCurrentEpoch() + offset - 1) * epochLength + startingTime),
            numTokensToSell,
            1e18
        );
    }

    /// @notice Computes the max tick delta, i.e. max dutch auction amount, per epoch
    ///         Returns an 18 decimal fixed point value
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        // Safe from overflow since max value is (2**24-1) * 1e18
        return int256(endingTick - startingTick) * 1e18 / int256((endingTime - startingTime) / epochLength);
    }

    /// @notice Aligns a given tick with the tickSpacing of the pool
    ///         Rounds down according to the asset token denominated price
    /// @param tick The tick to align
    /// @param tickSpacing The tick spacing of the pool
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

    /// @notice Given the tick range for the lower slug, computes the amount of proceeds required to allow
    ///         for all purchased asset tokens to be sold back into the curve
    /// @param sqrtPriceLower The sqrt price of the lower tick
    /// @param sqrtPriceUpper The sqrt price of the upper tick
    /// @param amount The amount of asset tokens which the liquidity needs to support the sale of
    function _computeRequiredProceeds(uint160 sqrtPriceLower, uint160 sqrtPriceUpper, uint256 amount)
        internal
        view
        returns (uint256 requiredProceeds)
    {
        uint128 liquidity;
        if (isToken0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount);
            requiredProceeds = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, amount);
            requiredProceeds = SqrtPriceMath.getAmount0Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        }
    }

    /// @notice Computes the global lower and upper ticks based on the accumulator and tickSpacing
    ///         These ticks represent the global range of the bonding curve, across all liquidity slugs
    /// @param accumulator The tickAccumulator value
    /// @param tickSpacing The tick spacing of the pool
    /// @return lower The computed global lower tick
    /// @return upper The computed global upper tick
    function _getTicksBasedOnState(int256 accumulator, int24 tickSpacing)
        internal
        view
        returns (int24 lower, int24 upper)
    {
        int24 accumulatorDelta = int24(accumulator / 1e18);
        int24 adjustedTick = startingTick + accumulatorDelta;
        lower = _alignComputedTickWithTickSpacing(adjustedTick, tickSpacing);

        // We don't need to align the upper tick since gamma is a multiple of tickSpacing
        if (isToken0) {
            upper = lower + gamma;
        } else {
            upper = lower - gamma;
        }
    }

    /// @notice Computes the lower slug ticks and liquidity
    ///         If there are insufficient proceeds, we switch to a single tick range at the target price
    ///         If there are sufficient proceeds, we use the range from the global tickLower to the current tick
    /// @param key The pool key
    /// @param requiredProceeds The amount of proceeds required to support the sale of all asset tokens
    /// @param totalProceeds_ The total amount of proceeds earned from selling tokens
    ///                       Bound to the amount of numeraire tokens available, which may be slightly less
    /// @param totalTokensSold_ The total amount of tokens sold
    /// @param tickLower The global tickLower of the bonding curve
    /// @param currentTick The current tick of the pool
    /// @return slug The computed lower slug data
    function _computeLowerSlugData(
        PoolKey memory key,
        uint256 requiredProceeds,
        uint256 totalProceeds_,
        uint256 totalTokensSold_,
        int24 tickLower,
        int24 currentTick
    ) internal view returns (SlugData memory slug) {
        // If we do not have enough proceeds to place the full lower slug,
        // we switch to a single tick range at the target price
        if (requiredProceeds > totalProceeds_) {
            slug = _computeLowerSlugInsufficientProceeds(key, totalProceeds_, totalTokensSold_);
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

        // We make sure that the lower tick and upper tick are equal if no liquidity,
        // else we don't properly enforce that swaps can't be made below the lower slug
        if (slug.liquidity == 0) {
            slug.tickLower = slug.tickUpper;
        }
    }

    /// @notice Computes the upper slug ticks and liquidity
    ///         Places a slug with the range according to the per epoch gamma, starting at the current tick
    ///         Provides the amount of tokens required to reach the expected amount sold by next epoch
    ///         If we have already sold more tokens than expected by next epoch, we don't place a slug
    /// @param key The pool key
    /// @param totalTokensSold_ The total amount of tokens sold
    /// @param currentTick The current tick of the pool
    /// @param assetAvailable The amount of asset tokens available to provide liquidity
    /// @return slug The computed upper slug data
    /// @return assetRemaining The amount of asset tokens remaining after providing liquidity
    function _computeUpperSlugData(
        PoolKey memory key,
        uint256 totalTokensSold_,
        int24 currentTick,
        uint256 assetAvailable
    ) internal view returns (SlugData memory slug, uint256 assetRemaining) {
        // Compute the delta between the amount of tokens sold relative to the expected amount sold by next epoch
        int256 tokensSoldDelta = int256(_getExpectedAmountSoldWithEpochOffset(1)) - int256(totalTokensSold_);

        uint256 tokensToLp;
        // If we have sold less tokens than expected, we place a slug with the amount of tokens to sell to reach
        // the expected amount sold by next epoch
        if (tokensSoldDelta > 0) {
            tokensToLp = uint256(tokensSoldDelta) > assetAvailable ? assetAvailable : uint256(tokensSoldDelta);
            int24 computedDelta =
                int24(int256(FullMath.mulDiv(uint256(_getGammaShare()), uint256(int256(gamma)), 1e18)));
            int24 accumulatorDelta = computedDelta > key.tickSpacing ? computedDelta : key.tickSpacing;
            slug.tickLower = currentTick;
            slug.tickUpper = _alignComputedTickWithTickSpacing(
                isToken0 ? slug.tickLower + accumulatorDelta : slug.tickLower - accumulatorDelta, key.tickSpacing
            );
        } else {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
        }

        // We compute the amount of liquidity to place only if the tick range is non-zero
        if (slug.tickLower != slug.tickUpper) {
            slug.liquidity = _computeLiquidity(
                isToken0,
                TickMath.getSqrtPriceAtTick(slug.tickLower),
                TickMath.getSqrtPriceAtTick(slug.tickUpper),
                tokensToLp
            );
        } else {
            slug.liquidity = 0;
        }

        assetRemaining = assetAvailable - tokensToLp;
    }

    /// @notice Computes the price discovery slugs ticks and liquidity
    ///         Places equidistant slugs up to the global tickUpper
    ///         Places one epoch worth of tokens to sell in each slug, bounded by the amount available
    ///         Stops placing slugs if we run out of future epochs to place for
    /// @param key The pool key
    /// @param upperSlug The computed upper slug data
    /// @param tickUpper The global tickUpper of the bonding curve
    /// @param assetAvailable The amount of asset tokens available to provide liquidity
    function _computePriceDiscoverySlugsData(
        PoolKey memory key,
        SlugData memory upperSlug,
        int24 tickUpper,
        uint256 assetAvailable
    ) internal view returns (SlugData[] memory) {
        SlugData[] memory slugs = new SlugData[](numPDSlugs);

        // Compute end time of current epoch
        uint256 epochEndTime = _getEpochEndWithOffset(0);
        // Compute end time of next epoch
        uint256 nextEpochEndTime = _getEpochEndWithOffset(1);

        // Return early if we're on the final epoch
        if (nextEpochEndTime == epochEndTime) {
            return slugs;
        }

        uint256 epochT1toT2Delta = _getNormalizedTimeElapsed(nextEpochEndTime) - _getNormalizedTimeElapsed(epochEndTime);

        int24 slugRangeDelta = (tickUpper - upperSlug.tickUpper) / int24(int256(numPDSlugs));
        if (isToken0) {
            slugRangeDelta = slugRangeDelta < key.tickSpacing ? key.tickSpacing : slugRangeDelta;
        } else {
            slugRangeDelta = slugRangeDelta < -key.tickSpacing ? slugRangeDelta : -key.tickSpacing;
        }

        uint256 pdSlugsToLp = numPDSlugs;
        for (uint256 i = numPDSlugs; i > 0; --i) {
            if (_getEpochEndWithOffset(i - 1) != _getEpochEndWithOffset(i)) {
                break;
            }
            --pdSlugsToLp;
        }

        uint256 tokensToLp = FullMath.mulDiv(epochT1toT2Delta, numTokensToSell, 1e18);
        bool surplusAssets = tokensToLp * pdSlugsToLp <= assetAvailable;
        tokensToLp = surplusAssets ? tokensToLp : assetAvailable / pdSlugsToLp;
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
            slugs[i].tickUpper = _alignComputedTickWithTickSpacing(slugs[i].tickLower + slugRangeDelta, key.tickSpacing);

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

    /// @notice Compute the target price given a numerator and denominator
    ///         Converts to Q96
    /// @param num The numerator
    /// @param denom The denominator
    function _computeTargetPriceX96(uint256 num, uint256 denom) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(num, FixedPoint96.Q96, denom));
    }

    /// @notice Computes the single sided liquidity amount for a given price range and amount of tokens
    /// @param forToken0 Whether the liquidity is for token0
    /// @param lowerPrice The lower sqrt price of the range
    /// @param upperPrice The upper sqrt price of the range
    /// @param amount The amount of tokens to place as liquidity
    function _computeLiquidity(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        // We decrement the amount by 1 to avoid rounding errors
        amount = amount != 0 ? amount - 1 : amount;

        if (forToken0) {
            return LiquidityAmounts.getLiquidityForAmount0(lowerPrice, upperPrice, amount);
        } else {
            return LiquidityAmounts.getLiquidityForAmount1(lowerPrice, upperPrice, amount);
        }
    }

    /// @notice Clears the positions in the pool, accounts for accrued fees, and returns the balance deltas
    /// @param lastEpochPositions The positions to clear
    /// @param key The pool key
    /// @return deltas The balance deltas from removing liquidity
    function _clearPositions(Position[] memory lastEpochPositions, PoolKey memory key)
        internal
        returns (BalanceDelta deltas)
    {
        for (uint256 i; i < lastEpochPositions.length; ++i) {
            if (lastEpochPositions[i].liquidity != 0) {
                (BalanceDelta positionDeltas, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: isToken0 ? lastEpochPositions[i].tickLower : lastEpochPositions[i].tickUpper,
                        tickUpper: isToken0 ? lastEpochPositions[i].tickUpper : lastEpochPositions[i].tickLower,
                        liquidityDelta: -int128(lastEpochPositions[i].liquidity),
                        salt: bytes32(uint256(lastEpochPositions[i].salt))
                    }),
                    ""
                );
                deltas = add(deltas, positionDeltas);
                state.feesAccrued = add(state.feesAccrued, feesAccrued);
            }
        }
    }

    /// @notice Updates the positions in the pool, accounts for accrued fees, and swaps to new price if necessary
    /// @param newPositions The new positions to add
    /// @param currentPrice The current price of the pool
    /// @param swapPrice The target price to swap to
    /// @param key The pool key
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
                poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: isToken0 ? newPositions[i].tickLower : newPositions[i].tickUpper,
                        tickUpper: isToken0 ? newPositions[i].tickUpper : newPositions[i].tickLower,
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

    /// @notice Callback to add liquidity to the pool in afterInitialize
    /// @param data The callback data (key, sender, tick)
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        (PoolKey memory key,, int24 tick) = (callbackData.key, callbackData.sender, callbackData.tick);
        state.lastEpoch = 1;

        (, int24 tickUpper) = _getTicksBasedOnState(0, key.tickSpacing);
        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(tick);
        uint160 sqrtPriceCurrent = TickMath.getSqrtPriceAtTick(tick);

        // set the tickLower and tickUpper to the current tick as this is the default behavior when requiredProceeds and totalProceeds are 0
        SlugData memory lowerSlug = SlugData({tickLower: tick, tickUpper: tick, liquidity: 0});
        (SlugData memory upperSlug, uint256 assetRemaining) = _computeUpperSlugData(key, 0, tick, numTokensToSell);
        SlugData[] memory priceDiscoverySlugs =
            _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, assetRemaining);

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

        _update(newPositions, sqrtPriceCurrent, sqrtPriceNext, key);

        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];
        for (uint256 i; i < numPDSlugs; ++i) {
            positions[bytes32(uint256(3 + i))] = newPositions[2 + i];
        }

        return new bytes(0);
    }

    /// @notice Computes the lower slug ticks and liquidity when there are insufficient proceeds
    ///         Places a single tickSpacing range at the average clearing price
    /// @param key The pool key
    /// @param totalProceeds_ The total amount of proceeds earned from selling tokens
    /// @param totalTokensSold_ The total amount of tokens sold
    function _computeLowerSlugInsufficientProceeds(PoolKey memory key, uint256 totalProceeds_, uint256 totalTokensSold_)
        internal
        view
        returns (SlugData memory slug)
    {
        uint160 targetPriceX96;
        if (isToken0) {
            // Q96 Target price (not sqrtPrice)
            targetPriceX96 = _computeTargetPriceX96(totalProceeds_, totalTokensSold_);
        } else {
            // Q96 Target price (not sqrtPrice)
            targetPriceX96 = _computeTargetPriceX96(totalTokensSold_, totalProceeds_);
        }

        slug.tickUpper = _alignComputedTickWithTickSpacing(
            // We compute the sqrtPrice as the integer sqrt left shifted by 48 bits to convert to Q96
            TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(uint256(targetPriceX96)) << 48)),
            key.tickSpacing
        );
        slug.tickLower = isToken0 ? slug.tickUpper - key.tickSpacing : slug.tickUpper + key.tickSpacing;

        slug.liquidity = _computeLiquidity(
            !isToken0,
            TickMath.getSqrtPriceAtTick(slug.tickLower),
            TickMath.getSqrtPriceAtTick(slug.tickUpper),
            totalProceeds_
        );
    }

    /// @notice Returns a struct of permissions to signal which hook functions are to be implemented
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
error InvalidSwap();
error InvalidProceedLimits();
error InvalidNumPDSlugs();
error InvalidSwapAfterMaturitySufficientProceeds();
error InvalidSwapAfterMaturityInsufficientProceeds();
error MaximumProceedsReached();
