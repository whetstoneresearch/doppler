// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta, add, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { TransientStateLibrary } from "@v4-core/libraries/TransientStateLibrary.sol";
import { FixedPointMathLib } from "@solady/utils/FixedPointMathLib.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { SwapMath } from "@v4-core/libraries/SwapMath.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import "forge-std/console.sol";

/// @notice Data for a liquidity slug, an intermediate representation of a `Position`
/// @dev Output struct when computing slug data for a `Position`
/// @param tickLower Lower tick boundary of the position (in terms of price numeraire/asset, not tick direction)
/// @param tickUpper Upper tick boundary of the position (in terms of price numeraire/asset, not tick direction)
/// @param liquidity Amount of liquidity in the position
struct SlugData {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

// @notice Current state of the Doppler pool
/// @dev Packed struct containing epoch data, accumulators, and total amounts
/// @param lastEpoch Last updated epoch (1-indexed)
/// @param tickAccumulator Accumulator to track the net bonding curve delta
/// @param totalTokensSold Total tokens sold by the hook
/// @param totalProceeds Total amount earned from selling tokens (in numeraire token)
/// @param totalTokensSoldLastEpoch Total tokens sold at the end of the last epoch
/// @param feesAccrued Fees accrued to the pool since last collection
struct State {
    uint40 lastEpoch;
    int256 tickAccumulator;
    uint256 totalTokensSold;
    uint256 totalProceeds;
    uint256 totalTokensSoldLastEpoch;
    BalanceDelta feesAccrued;
}

/// @notice Position data for a liquidity slug
/// @dev Used to track individual liquidity positions controlled by the hook
/// @param tickLower Lower tick boundary of the position (in terms of price numeraire/asset, not tick direction)
/// @param tickUpper Upper tick boundary of the position (in terms of price numeraire/asset, not tick direction)
/// @param liquidity Amount of liquidity in the position
/// @param salt Salt value used to identify the position
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

error InvalidGamma();

/// @notice Thrown when the time range is invalid (likely start is after end)
error InvalidTimeRange();

/// @notice Thrown when an attempt is made to add liquidity to the pool
error CannotAddLiquidity();

/// @notice Thrown when an attempt is made to swap before the start time
error CannotSwapBeforeStartTime();

/// @notice Thrown when an attempt is made to swap below the range of the lower slug
error SwapBelowRange();

/// @notice Thrown when start time is before the current block.timestamp
error InvalidStartTime();

/// @notice Thrown when the time range is invalid (likely start is after end)
error InvalidTickRange();

/// @notice Thrown when the tick spacing is invalid (likely too large)
error InvalidTickSpacing();

/// @notice Thrown when the epoch length is invalid (likely not divisible by the time range)
error InvalidEpochLength();

/// @notice Thrown when the proceeds limits are invalid (likely min > max)
error InvalidProceedLimits();

/// @notice Thrown when the number of price discovery slugs is invalid (likely too large)
error InvalidNumPDSlugs();

/// @notice Thrown when a swap is attempted after migration
error InvalidSwapAfterMaturitySufficientProceeds();

/// @notice Thrown when a swap is attempting to buy assets after sale has ended
error InvalidSwapAfterMaturityInsufficientProceeds();

/// @notice Thrown when the pool has already reached the maximum proceeds
error MaximumProceedsReached();

/// @notice Thrown when the caller is not the pool manager
error SenderNotPoolManager();

/// @notice Thrown when the pool is not ready for migration
error CannotMigrate();

/// @notice Thrown when the pool is already initialized
error AlreadyInitialized();

/// @notice Thrown when the sender is not the initializer of the pool
error SenderNotInitializer();

/// @notice Thrown when a donation is attempted
error CannotDonate();

/**
 * @notice Emitted when the pool rebalances
 * @param currentTick Current tick of the pool
 * @param tickLower Lower tick
 * @param tickUpper Upper tick
 * @param epoch Current epoch
 */
event Rebalance(int24 currentTick, int24 tickLower, int24 tickUpper, uint256 epoch);

/**
 * @notice Emitted when a swap occurs
 * @param currentTick Current tick of the pool
 * @param totalProceeds Total proceeds
 * @param totalTokensSold Total tokens sold
 */
event Swap(int24 currentTick, uint256 totalProceeds, uint256 totalTokensSold);

/**
 * @notice Emitted when the pool reaches the early exit state
 * @param epoch Current epoch
 */
event EarlyExit(uint256 epoch);

/// @notice Emitted when the pool reaches the insufficient proceeds state
event InsufficientProceeds();

/// @dev Maximum swap fee for the pool
uint256 constant MAX_SWAP_FEE = SwapMath.MAX_SWAP_FEE;

/// @dev Precision multiplier for unsigned integers
uint256 constant WAD = 1e18;

/// @dev Precision multiplier for signed integers
int256 constant I_WAD = 1e18;

/// @dev Maximum tick spacing for the pool
int24 constant MAX_TICK_SPACING = 30;

/// @dev Maximum number of price discovery slugs
uint256 constant MAX_PRICE_DISCOVERY_SLUGS = 10;

/// @dev Number of default slugs
uint256 constant NUM_DEFAULT_SLUGS = 3;

/// @dev Used to differentiate between the lower, upper, and price discovery slugs
bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
/// @dev Demarcates the id of the LOWEST (price-wise) price discovery slug
bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

/// @title Doppler
/// @author kadenzipfel, kinrezC, clemlak, aadams, and Alexangelj
/// @custom:security-contact security@whetstone.cc
contract Doppler is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;
    using SafeCastLib for uint128;
    using SafeCastLib for int256;
    using SafeCastLib for uint256;

    /// @notice True if the pool matured and the minimum proceeds were not met
    bool public insufficientProceeds;

    /// @notice True if the pool reached or exceeded the maximum proceeds
    bool public earlyExit;

    /// @notice State of the pool, see `State` struct
    State public state;

    /// @notice Positions held by the hook
    mapping(bytes32 salt => Position position) public positions;

    /// @notice True if the hook was already initialized, used to prevent
    /// another pool from reusing the hook and messing with its state
    bool public isInitialized;

    // The following variables are NOT immutable to avoid hitting the contract size limit

    /// @notice Uniswap V4 pool key associated with this hook
    PoolKey public poolKey;

    /// @notice Address triggering the deployment and later the migration, likely the Airlock contract
    address public initializer;

    /// @notice Total amount of tokens to be sold
    uint256 public numTokensToSell;

    /// @notice Minimum proceeds required to avoid refund phase
    uint256 public minimumProceeds;

    /// @notice Maximum proceeds amount that will trigger early exit condition
    uint256 public maximumProceeds;

    /// @notice Sale start time
    uint256 public startingTime;

    /// @notice Sale end time
    uint256 public endingTime;

    /// @notice Dutch auction starting tick
    int24 public startingTick;

    /// @notice Dutch auction ending tick
    int24 public endingTick;

    /// @notice Length of each epoch (in seconds)
    uint256 public epochLength;

    /// @notice Maximum tick change for the entire bonding curve (1.0001 ** (gamma))
    int24 public gamma;

    /// @notice True if token0 is the token being sold
    bool public isToken0;

    /// @notice Number of price discovery slugs
    uint256 public numPDSlugs;

    /// @notice Initial swap fee for the pool
    uint24 public initialLpFee;

    /// @dev Total number of epochs
    uint256 internal totalEpochs;

    /// @dev Range of the upper slug
    int24 internal upperSlugRange;

    /// @notice Only the pool manager can send ETH to this contract
    receive() external payable {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();
    }

    /// @notice Creates a new Doppler pool instance
    /// @dev Validates input parameters and sets up the initial pool state
    /// @param poolManager_ The Uniswap v4 pool manager contract
    /// @param numTokensToSell_ Total number of tokens available to be sold by the hook
    /// @param minimumProceeds_ Proceeds required to avoid refund phase
    /// @param maximumProceeds_ Proceeds amount that trigger early exit
    /// @param startingTime_ Unix timestamp when the sale starts
    /// @param endingTime_ Unix timestamp when the sale ends
    /// @param startingTick_ Initial tick for the bonding curve
    /// @param endingTick_ Final tick for the bonding curve
    /// @param epochLength_ Duration of each epoch in seconds
    /// @param gamma_ 1.0001^gamma, represents the maximum tick change for the entire bonding curve
    /// @param isToken0_ Whether token0 is the asset being sold (true) or token1 (false)
    /// @param numPDSlugs_ Number of price discovery slugs to use
    /// @param initialLpFee_ Initial swap fee
    constructor(
        IPoolManager poolManager_,
        uint256 numTokensToSell_,
        uint256 minimumProceeds_,
        uint256 maximumProceeds_,
        uint256 startingTime_,
        uint256 endingTime_,
        int24 startingTick_,
        int24 endingTick_,
        uint256 epochLength_,
        int24 gamma_,
        bool isToken0_,
        uint256 numPDSlugs_,
        address initializer_,
        uint24 initialLpFee_
    ) BaseHook(poolManager_) {
        initialLpFee = initialLpFee_;

        // Check that the current time is before the starting time
        if (block.timestamp > startingTime_) revert InvalidStartTime();
        /* Tick checks */
        // Starting tick must be greater than ending tick if isToken0
        // Ending tick must be greater than starting tick if isToken1
        if (startingTick_ != endingTick_) {
            if (isToken0_ && startingTick_ < endingTick_) revert InvalidTickRange();
            if (!isToken0_ && startingTick_ > endingTick_) revert InvalidTickRange();
        }

        /* Time checks */
        // Starting time must be less than ending time
        if (startingTime_ >= endingTime_) revert InvalidTimeRange();
        uint256 timeDelta = endingTime_ - startingTime_;
        // Inconsistent gamma, epochs must be long enough such that the upperSlug is at least 1 tick
        if (
            gamma_ <= 0
                || FullMath.mulDiv(FullMath.mulDiv(epochLength_, WAD, timeDelta), uint256(int256(gamma_)), WAD) == 0
        ) {
            revert InvalidGamma();
        }
        // _endingTime - startingTime must be divisible by epochLength
        if (timeDelta % epochLength_ != 0) revert InvalidEpochLength();

        /* Num price discovery slug checks */
        if (numPDSlugs_ == 0) revert InvalidNumPDSlugs();
        if (numPDSlugs_ > MAX_PRICE_DISCOVERY_SLUGS) revert InvalidNumPDSlugs();

        // These can both be zero
        if (minimumProceeds_ > maximumProceeds_) revert InvalidProceedLimits();

        totalEpochs = timeDelta / epochLength_;
        uint256 normalizedEpochDelta = FullMath.mulDiv(epochLength_, WAD, timeDelta);
        // Safe from overflow since the result is <= gamma which is an int24 already
        // Cannot check if upperSlugRange > tickSpacing because poolKey unknown
        upperSlugRange = FullMath.mulDiv(normalizedEpochDelta, uint256(int256(gamma_)), WAD).toInt24();

        numTokensToSell = numTokensToSell_;
        minimumProceeds = minimumProceeds_;
        maximumProceeds = maximumProceeds_;
        startingTime = startingTime_;
        endingTime = endingTime_;
        startingTick = startingTick_;
        endingTick = endingTick_;
        epochLength = epochLength_;
        gamma = gamma_;
        isToken0 = isToken0_;
        numPDSlugs = numPDSlugs_;
        initializer = initializer_;
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (isInitialized) revert AlreadyInitialized();
        isInitialized = true;
        poolKey = key;

        // Enforce maximum tick spacing
        if (key.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();

        /* Gamma checks */
        // Enforce that the total tick delta is divisible by the total number of epochs
        // Enforce that gamma is divisible by tick spacing
        if (gamma % key.tickSpacing != 0) revert InvalidGamma();

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Called by poolManager following initialization, used to place initial liquidity slugs
    /// @param sender The address that called poolManager.initialize
    /// @param key The pool key
    /// @param tick The initial tick of the pool
    /// @return The function selector for afterInitialize
    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, initialLpFee);
        poolManager.unlock(abi.encode(CallbackData({ key: key, sender: sender, tick: tick, isMigration: false })));
        return BaseHook.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert CannotDonate();
    }

    /// @notice Called by the poolManager immediately before a swap is executed
    ///         Triggers rebalancing logic in new epochs and handles early exit/insufficient proceeds outcomes
    /// @param key The pool key
    /// @param swapParams The parameters for swapping
    /// @return selector The function selector for beforeSwap
    /// @return delta The delta to apply before the swap
    /// @return feeOverride Optional fee override, this is set to 0 in doppler
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (earlyExit) revert MaximumProceedsReached();

        if (block.timestamp < startingTime) revert CannotSwapBeforeStartTime();

        // We can skip rebalancing if we're in an epoch that already had a rebalance
        if (_getCurrentEpoch() <= uint256(state.lastEpoch)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 fee;

        // Only check proceeds if we're after maturity and we haven't already triggered insufficient proceeds
        if (block.timestamp >= endingTime && !insufficientProceeds) {
            // If we haven't raised the minimum proceeds, we allow for all asset tokens to be sold back into
            // the curve at the average clearing price
            if (state.totalProceeds < minimumProceeds) {
                insufficientProceeds = true;
                emit InsufficientProceeds();
                PoolId poolId = key.toId();
                (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
                int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPrice); // read current tick based sqrtPrice as its more accurate in extreme edge cases

                Position[] memory prevPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + numPDSlugs);
                prevPositions[0] = positions[LOWER_SLUG_SALT];
                prevPositions[1] = positions[UPPER_SLUG_SALT];
                for (uint256 i; i < numPDSlugs; ++i) {
                    prevPositions[NUM_DEFAULT_SLUGS - 1 + i] = positions[bytes32(uint256(NUM_DEFAULT_SLUGS + i))];
                }

                // Place all available numeraire in the lower slug at the average clearing price
                (BalanceDelta delta, BalanceDelta feeDelta) = _clearPositions(prevPositions, key);
                uint256 numeraireAvailable = uint256(uint128(isToken0 ? delta.amount1() : delta.amount0()));

                SlugData memory lowerSlug =
                    _computeLowerSlugInsufficientProceeds(key, numeraireAvailable, state.totalTokensSold, currentTick);
                Position[] memory newPositions = new Position[](1);

                newPositions[0] = Position({
                    tickLower: lowerSlug.tickLower,
                    tickUpper: lowerSlug.tickUpper,
                    liquidity: lowerSlug.liquidity,
                    salt: uint8(uint256(LOWER_SLUG_SALT))
                });

                // Include tickSpacing so we're at least at a higher price than the lower slug upper tick
                uint160 sqrtPriceX96Next =
                    TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper + (isToken0 ? key.tickSpacing : -key.tickSpacing));

                uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
                _update(newPositions, sqrtPriceX96, sqrtPriceX96Next, key);
                positions[LOWER_SLUG_SALT] = newPositions[0];

                // Add 1 to numPDSlugs because we don't need to clear the lower slug
                // but we do need to clear the upper/pd slugs
                for (uint256 i; i < numPDSlugs + 1; ++i) {
                    delete positions[bytes32(uint256(NUM_DEFAULT_SLUGS - 1 + i))];
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
            if ((isToken0 && swapParams.zeroForOne == false) || (!isToken0 && swapParams.zeroForOne)) {
                revert InvalidSwapAfterMaturityInsufficientProceeds();
            }

            fee = 0 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        console.log("fee in beforeSwap", fee);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /// @notice Called by the poolManager immediately after a swap is executed
    ///         Used to update totalTokensSold and totalProceeds with swap amounts, excluding fees
    ///         If we've exceeded the maximumProceeds, we trigger the early exit condition
    ///         We revert if the swap is below the range of the lower slug to prevent manipulation
    /// @param key The pool key
    /// @param swapDelta The balance delta of the address swapping
    /// @return selector The function selector for afterSwap
    /// @return delta The delta amount to return to the pool manager (always 0)
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Get current tick
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96); // read current tick based sqrtPrice as its more accurate in extreme edge cases
        console.log("lpFee", lpFee);

        // Get the lower tick of the lower slug
        int24 tickLower = positions[LOWER_SLUG_SALT].tickLower;
        uint24 swapFee = (swapParams.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee())
            .calculateSwapFee(lpFee);

        console.log("isToken0", isToken0);
        console.log("totalProceedsBefore", state.totalProceeds);
        console.log("totalTokensSoldBefore", state.totalTokensSold);
        console.log("swapDelta0", swapDelta.amount0());
        console.log("swapDelta1", swapDelta.amount1());

        console.log("swapFee", swapFee);

        if (isToken0) {
            if (currentTick < tickLower) revert SwapBelowRange();

            int128 amount0 = swapDelta.amount0();
            if (amount0 >= 0) {
                state.totalTokensSold += uint128(amount0);
            } else {
                uint256 tokensSoldLessFee = FullMath.mulDiv(uint128(-amount0), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalTokensSold -= tokensSoldLessFee;
            }

            int128 amount1 = swapDelta.amount1();
            if (amount1 >= 0) {
                state.totalProceeds -= uint128(amount1);
            } else {
                uint256 proceedsLessFee = FullMath.mulDiv(uint128(-amount1), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalProceeds += proceedsLessFee;
            }
        } else {
            if (currentTick > tickLower) revert SwapBelowRange();

            int128 amount1 = swapDelta.amount1();
            if (amount1 >= 0) {
                state.totalTokensSold += uint128(amount1);
            } else {
                uint256 tokensSoldLessFee = FullMath.mulDiv(uint128(-amount1), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalTokensSold -= tokensSoldLessFee;
            }

            int128 amount0 = swapDelta.amount0();
            if (amount0 >= 0) {
                state.totalProceeds -= uint128(amount0);
            } else {
                uint256 proceedsLessFee = FullMath.mulDiv(uint128(-amount0), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);
                state.totalProceeds += proceedsLessFee;
            }
        }

        console.log("totalProceedsAfter", state.totalProceeds);
        console.log("totalTokensSoldAfter", state.totalTokensSold);

        // If we reach or exceed the maximumProceeds, we trigger the early exit condition
        if (state.totalProceeds >= maximumProceeds) {
            earlyExit = true;
            emit EarlyExit(_getCurrentEpoch());
        }

        emit Swap(currentTick, state.totalProceeds, state.totalTokensSold);

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Called by the poolManager immediately before liquidity is added
    ///         We revert if the caller is not this contract
    /// @param caller The address that called poolManager.modifyLiquidity
    /// @return The function selector for beforeAddLiquidity
    function _beforeAddLiquidity(
        address caller,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override onlyPoolManager returns (bytes4) {
        if (caller != address(this)) revert CannotAddLiquidity();

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Executed before swaps in new epochs to rebalance the bonding curve
    ///         We adjust the bonding curve according to the amount tokens sold relative to the expected amount
    /// @dev Called during beforeSwap when entering a new epoch
    /// @param key The pool key
    function _rebalance(
        PoolKey calldata key
    ) internal {
        // We increment by 1 to 1-index the epoch
        uint256 currentEpoch = _getCurrentEpoch();
        uint256 epochsPassed = currentEpoch - uint256(state.lastEpoch);

        state.lastEpoch = uint40(currentEpoch);

        // Cache state var to avoid multiple SLOADs
        uint256 totalTokensSold_ = state.totalTokensSold;

        Position memory upperSlugPosition = positions[UPPER_SLUG_SALT];

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96); // read current tick based sqrtPrice as its more accurate in extreme edge cases
        currentTick = _alignComputedTickWithTickSpacing(currentTick, key.tickSpacing);

        int256 accumulatorDelta;
        int256 newAccumulator;
        int24 adjustmentTick;
        // Handle empty epochs
        // accumulatorDelta should always be nonzero if epochsPassed > 1, so we don't need the check
        if (epochsPassed > 1) {
            // handle the price adjustment that should have happened in the first empty epoch
            int256 initialNetSold = int256(totalTokensSold_) - int256(state.totalTokensSoldLastEpoch);
            bool lteExpectedSoldInFirstEpoch =
                totalTokensSold_ <= _getExpectedAmountSoldWithEpochOffset(-int256(epochsPassed - 1));

            if (initialNetSold < 0 && lteExpectedSoldInFirstEpoch) {
                accumulatorDelta += _getMaxTickDeltaPerEpoch();
            } else if (lteExpectedSoldInFirstEpoch) {
                accumulatorDelta += _getMaxTickDeltaPerEpoch()
                    * int256(
                        WAD
                            - FullMath.mulDiv(
                                totalTokensSold_, WAD, _getExpectedAmountSoldWithEpochOffset(-int256(epochsPassed - 1))
                            )
                    ) / I_WAD;
            } else {
                int24 tauTick = startingTick + int24(state.tickAccumulator / I_WAD);

                int24 adjustmentTickDelta = upperSlugRange > key.tickSpacing ? upperSlugRange : key.tickSpacing;

                // The expectedTick is where the upperSlug.tickUpper is/would be placed in the previous epoch
                // The upperTick is not always placed so we have to compute its placement in case it's not
                // This depends on the invariant that upperSlug.tickLower == currentTick at the time of rebalancing
                adjustmentTick = isToken0
                    ? upperSlugPosition.tickLower + adjustmentTickDelta
                    : upperSlugPosition.tickLower - adjustmentTickDelta;
                int24 expectedTick = _alignComputedTickWithTickSpacing(adjustmentTick, key.tickSpacing);

                uint256 epochsRemaining = totalEpochs - currentEpoch;
                int24 liquidityBound = isToken0 ? tauTick + gamma : tauTick - gamma;
                liquidityBound = epochsRemaining < numPDSlugs
                    ? positions[bytes32(uint256(NUM_DEFAULT_SLUGS + epochsRemaining))].tickUpper
                    : liquidityBound;

                // We bound the currentTick by the top of the curve (tauTick + gamma)
                // This is necessary because there is no liquidity above the curve and we need to
                // ensure that the accumulatorDelta is just based on meaningful (in range) ticks
                if (isToken0) {
                    currentTick = currentTick > liquidityBound ? liquidityBound : currentTick;
                } else {
                    currentTick = currentTick < liquidityBound ? liquidityBound : currentTick;
                }

                accumulatorDelta += int256(currentTick - expectedTick) * I_WAD;
            }

            // apply max tick delta for remaining empty epochs
            // -2 because we already applied the first empty epoch and will apply the last epoch later
            // only max DA for every epoch where we are below expected amount sold
            uint256 expectedSoldInLastEpoch = _getExpectedAmountSoldWithEpochOffset(-2);
            bool isLtExpectedSoldInLastEpoch = totalTokensSold_ < expectedSoldInLastEpoch;

            if (isLtExpectedSoldInLastEpoch) {
                // find how many empty epochs are implied by the difference between expected amount sold and total tokens sold
                int256 offset = -2;
                uint256 expectedSold = expectedSoldInLastEpoch;
                uint256 emptyEpochs;

                do {
                    emptyEpochs++;
                    offset--;
                    expectedSold = _getExpectedAmountSoldWithEpochOffset(offset);
                    isLtExpectedSoldInLastEpoch = totalTokensSold_ < expectedSold;
                } while (isLtExpectedSoldInLastEpoch);

                accumulatorDelta += _getMaxTickDeltaPerEpoch() * int256(emptyEpochs);
            }

            state.totalTokensSoldLastEpoch = totalTokensSold_;
        }

        // Get the expected amount sold and the net sold in the last epoch
        uint256 expectedAmountSold = _getExpectedAmountSoldWithEpochOffset(0);
        int256 netSold = int256(totalTokensSold_) - int256(state.totalTokensSoldLastEpoch);

        state.totalTokensSoldLastEpoch = totalTokensSold_;

        bool lteExpectedSold = totalTokensSold_ <= expectedAmountSold;

        // Possible if no tokens purchased or tokens are sold back into the pool
        if (netSold < 0 && lteExpectedSold) {
            adjustmentTick = upperSlugPosition.tickLower;
            accumulatorDelta += _getMaxTickDeltaPerEpoch();
        } else if (lteExpectedSold) {
            // Safe from overflow since we use 256 bits with a maximum value of (2**24-1) * 1e18
            adjustmentTick = _alignComputedTickWithTickSpacing(currentTick, key.tickSpacing);
            accumulatorDelta += _getMaxTickDeltaPerEpoch()
                * int256(WAD - FullMath.mulDiv(totalTokensSold_, WAD, expectedAmountSold)) / I_WAD;
        } else {
            int24 tauTick = startingTick + int24(state.tickAccumulator / I_WAD);

            int24 adjustmentTickDelta = upperSlugRange > key.tickSpacing ? upperSlugRange : key.tickSpacing;

            // The expectedTick is where the upperSlug.tickUpper is/would be placed in the previous epoch
            // The upperTick is not always placed so we have to compute its placement in case it's not
            // This depends on the invariant that upperSlug.tickLower == currentTick at the time of rebalancing
            adjustmentTick = isToken0
                ? upperSlugPosition.tickLower + adjustmentTickDelta
                : upperSlugPosition.tickLower - adjustmentTickDelta;
            int24 expectedTick = _alignComputedTickWithTickSpacing(adjustmentTick, key.tickSpacing);

            uint256 epochsRemaining = totalEpochs - currentEpoch;
            int24 liquidityBound = isToken0 ? tauTick + gamma : tauTick - gamma;
            liquidityBound = epochsRemaining < numPDSlugs
                ? positions[bytes32(uint256(NUM_DEFAULT_SLUGS + epochsRemaining))].tickUpper
                : liquidityBound;

            // We bound the currentTick by the top of the curve (tauTick + gamma)
            // This is necessary because there is no liquidity above the curve and we need to
            // ensure that the accumulatorDelta is just based on meaningful (in range) ticks
            if (isToken0) {
                currentTick = currentTick > liquidityBound ? liquidityBound : currentTick;
            } else {
                currentTick = currentTick < liquidityBound ? liquidityBound : currentTick;
            }

            accumulatorDelta += int256(currentTick - expectedTick) * I_WAD;
        }

        newAccumulator = state.tickAccumulator + accumulatorDelta;
        // Only sstore if there is a nonzero delta
        if (accumulatorDelta != 0) {
            state.tickAccumulator = newAccumulator;
        }

        currentTick =
            _alignComputedTickWithTickSpacing(adjustmentTick + (accumulatorDelta / I_WAD).toInt24(), key.tickSpacing);

        (int24 tickLower, int24 tickUpper) = _getTicksBasedOnState(newAccumulator, key.tickSpacing);

        // It's possible that these are equal
        // If we try to add liquidity in this range though, we revert with a divide by zero
        // Thus we have to create a gap between the two
        if (!isToken0 && currentTick >= tickLower) {
            tickLower = currentTick + key.tickSpacing;
        } else if (isToken0 && currentTick <= tickLower) {
            tickLower = currentTick - key.tickSpacing;
        }

        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);

        uint256 requiredProceeds =
            totalTokensSold_ != 0 ? _computeRequiredProceeds(sqrtPriceLower, sqrtPriceNext, totalTokensSold_) : 0;

        // Get existing positions
        Position[] memory prevPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + numPDSlugs);
        prevPositions[0] = positions[LOWER_SLUG_SALT];
        prevPositions[1] = positions[UPPER_SLUG_SALT];
        for (uint256 i; i < numPDSlugs; ++i) {
            prevPositions[NUM_DEFAULT_SLUGS - 1 + i] = positions[bytes32(uint256(NUM_DEFAULT_SLUGS + i))];
        }

        // Remove existing positions, track removed tokens
        (BalanceDelta positionDeltas, BalanceDelta feeDeltas) = _clearPositions(prevPositions, key);

        uint256 numeraireAvailable;
        uint256 assetAvailable;

        if (isToken0) {
            numeraireAvailable = uint256(uint128(positionDeltas.amount1())) - uint128(feeDeltas.amount1());
            assetAvailable = uint256(uint128(positionDeltas.amount0())) + key.currency0.balanceOfSelf()
                - uint128(feeDeltas.amount0());
        } else {
            numeraireAvailable = uint256(uint128(positionDeltas.amount0())) - uint128(feeDeltas.amount0());
            assetAvailable = uint256(uint128(positionDeltas.amount1())) + key.currency1.balanceOfSelf()
                - uint128(feeDeltas.amount1());
        }

        // Compute new positions
        SlugData memory lowerSlug =
            _computeLowerSlugData(key, requiredProceeds, numeraireAvailable, totalTokensSold_, tickLower, currentTick);
        (SlugData memory upperSlug, uint256 assetRemaining) =
            _computeUpperSlugData(key, totalTokensSold_, currentTick, assetAvailable);
        SlugData[] memory priceDiscoverySlugs =
            _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, assetRemaining);

        // Get new positions
        Position[] memory newPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + numPDSlugs);
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
            newPositions[NUM_DEFAULT_SLUGS - 1 + i] = Position({
                tickLower: priceDiscoverySlugs[i].tickLower,
                tickUpper: priceDiscoverySlugs[i].tickUpper,
                liquidity: priceDiscoverySlugs[i].liquidity,
                salt: uint8(NUM_DEFAULT_SLUGS + i)
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
                delete positions[bytes32(uint256(NUM_DEFAULT_SLUGS + i))];
            } else {
                positions[bytes32(uint256(NUM_DEFAULT_SLUGS + i))] = newPositions[NUM_DEFAULT_SLUGS - 1 + i];
            }
        }
        emit Rebalance(currentTick, tickLower, tickUpper, currentEpoch);
    }

    /// @notice If offset == 0, retrieves the end time of the current epoch
    ///         If offset == n, retrieves the end time of the nth epoch from the current
    /// @param offset The offset from the current epoch
    function _getEpochEndWithOffset(
        uint256 offset
    ) internal view returns (uint256) {
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
    function _getNormalizedTimeElapsed(
        uint256 timestamp
    ) internal view returns (uint256) {
        return FullMath.mulDiv(timestamp - startingTime, WAD, endingTime - startingTime);
    }

    /// @notice If offset == 0, retrieves the expected amount sold by the end of the last epoch
    ///         If offset == 1, retrieves the expected amount sold by the end of the current epoch
    ///         If offset == n, retrieves the expected amount sold by the end of the nth epoch from the current
    /// @param offset The epoch offset to retrieve for
    function _getExpectedAmountSoldWithEpochOffset(
        int256 offset
    ) internal view returns (uint256) {
        return FullMath.mulDiv(
            _getNormalizedTimeElapsed(
                uint256((int256(_getCurrentEpoch()) + offset - 1) * int256(epochLength) + int256(startingTime))
            ),
            numTokensToSell,
            WAD
        );
    }

    /// @notice Computes the max tick delta, i.e. max dutch auction amount, per epoch
    ///         Returns an 18 decimal fixed point value
    function _getMaxTickDeltaPerEpoch() internal view returns (int256) {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96); // read current tick based sqrtPrice as its more accurate in extreme edge cases

        int24 effectiveStartingTick;
        if (isToken0) {
            effectiveStartingTick = currentTick > startingTick ? currentTick : startingTick;
        } else {
            effectiveStartingTick = currentTick < startingTick ? currentTick : startingTick;
        }

        // Safe from overflow since max value is (2**24-1) * 1e18
        return int256(endingTick - effectiveStartingTick) * I_WAD / int256((endingTime - startingTime) / epochLength);
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
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
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
    function _computeRequiredProceeds(
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        uint256 amount
    ) internal view returns (uint256 requiredProceeds) {
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
    function _getTicksBasedOnState(
        int256 accumulator,
        int24 tickSpacing
    ) internal view returns (int24 lower, int24 upper) {
        int24 accumulatorDelta = (accumulator / I_WAD).toInt24();
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
        if (totalProceeds_ == 0) {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
            slug.liquidity = 0;
        } else if (requiredProceeds > totalProceeds_) {
            console.log("INSUFFICIENT PROCEEDS");
            slug = _computeLowerSlugInsufficientProceeds(key, totalProceeds_, totalTokensSold_, currentTick);
        } else {
            console.log("SUFFICIENT PROCEEDS");
            slug.tickLower = tickLower;
            slug.tickUpper = currentTick;
            slug.liquidity = _computeLiquidity(
                !isToken0,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(currentTick),
                requiredProceeds
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
            int24 accumulatorDelta = upperSlugRange > key.tickSpacing ? upperSlugRange : key.tickSpacing;
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
        // Compute end time of current epoch
        uint256 epochEndTime = _getEpochEndWithOffset(0);
        // Compute end time of next epoch
        uint256 nextEpochEndTime = _getEpochEndWithOffset(1);

        // Return early if we're on the final epoch
        if (nextEpochEndTime == epochEndTime) {
            return new SlugData[](0);
        }

        uint256 epochT1toT2Delta;
        if (epochEndTime != nextEpochEndTime) {
            epochT1toT2Delta = _getNormalizedTimeElapsed(nextEpochEndTime) - _getNormalizedTimeElapsed(epochEndTime);
        }

        uint256 pdSlugsToLp = numPDSlugs;
        for (uint256 i = numPDSlugs; i > 0; --i) {
            if (_getEpochEndWithOffset(i - 1) != _getEpochEndWithOffset(i)) {
                break;
            }
            --pdSlugsToLp;
        }

        int24 slugRangeDelta = (tickUpper - upperSlug.tickUpper) / int24(int256(pdSlugsToLp));
        if (isToken0) {
            slugRangeDelta = slugRangeDelta < key.tickSpacing ? key.tickSpacing : slugRangeDelta;
        } else {
            slugRangeDelta = slugRangeDelta < -key.tickSpacing ? slugRangeDelta : -key.tickSpacing;
        }

        uint256 tokensToLp = FullMath.mulDiv(epochT1toT2Delta, numTokensToSell, WAD);
        bool surplusAssets = tokensToLp * pdSlugsToLp <= assetAvailable;
        tokensToLp = surplusAssets ? tokensToLp : assetAvailable / pdSlugsToLp;
        int24 tick = upperSlug.tickUpper;

        SlugData[] memory slugs = new SlugData[](pdSlugsToLp);
        for (uint256 i; i < pdSlugsToLp; ++i) {
            slugs[i].tickLower = tick;
            tick = _alignComputedTickWithTickSpacing(slugs[i].tickLower + slugRangeDelta, key.tickSpacing);
            slugs[i].tickUpper = tick;

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
        uint256 targetPriceX96 = FullMath.mulDiv(num, FixedPoint96.Q96, denom);

        if (targetPriceX96 > type(uint160).max) {
            return 0;
        }

        return targetPriceX96.toUint160();
    }

    /// @notice Computes the single sided liquidity amount for a given price range and amount of tokens
    /// @param forToken0 Whether the liquidity is for token0
    /// @param lowerPrice The lower sqrt price of the range
    /// @param upperPrice The upper sqrt price of the range
    /// @param amount The amount of tokens to place as liquidity
    function _computeLiquidity(
        bool forToken0,
        uint160 lowerPrice,
        uint160 upperPrice,
        uint256 amount
    ) internal pure returns (uint128) {
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
    function _clearPositions(
        Position[] memory lastEpochPositions,
        PoolKey memory key
    ) internal returns (BalanceDelta deltas, BalanceDelta feeDeltas) {
        for (uint256 i; i < lastEpochPositions.length; ++i) {
            if (lastEpochPositions[i].liquidity != 0) {
                (BalanceDelta positionDeltas, BalanceDelta positionFeeDeltas) = poolManager.modifyLiquidity(
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
                feeDeltas = add(feeDeltas, positionFeeDeltas);
                state.feesAccrued = add(state.feesAccrued, positionFeeDeltas);
            }
        }
    }

    /// @notice Updates the positions in the pool, accounts for accrued fees, and swaps to new price if necessary
    /// @param newPositions The new positions to add
    /// @param currentPrice The current price of the pool
    /// @param swapPrice The target price to swap to
    /// @param key The pool key
    function _update(
        Position[] memory newPositions,
        uint160 currentPrice,
        uint160 swapPrice,
        PoolKey memory key
    ) internal {
        if (swapPrice != currentPrice) {
            // Since there's no liquidity in the pool, swapping a non-zero amount allows us to reset its price.
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: swapPrice < currentPrice,
                    amountSpecified: 1,
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
                        liquidityDelta: newPositions[i].liquidity.toInt128(),
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
            poolManager.settle();
        }

        if (currency1Delta < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(-currency1Delta));
            poolManager.settle();
        }
    }

    /// @dev Data passed through the `unlock` call to the PoolManager to the `_unlockCallback`
    /// back in this contract. Using a struct here is usually to avoid using the wrong types.
    /// @param key Pool key associated with this hook
    /// @param sender Address calling the PoolManager, for example the Airlock in a migration
    /// @param tick Current tick of the pool
    /// @param isMigration Whether or not we reached the migration stage
    struct CallbackData {
        PoolKey key;
        address sender;
        int24 tick;
        bool isMigration;
    }

    /// @notice Callback to add liquidity to the pool in afterInitialize
    /// @param data The callback data (key, sender, tick)
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        (PoolKey memory key, address sender, int24 tick, bool isMigration) =
            (callbackData.key, callbackData.sender, callbackData.tick, callbackData.isMigration);

        if (isMigration) {
            BalanceDelta slugsCallerDelta;
            BalanceDelta slugsFeesAccrued;

            for (uint256 i = 1; i < NUM_DEFAULT_SLUGS + numPDSlugs; ++i) {
                Position memory position = positions[bytes32(i)];

                if (position.liquidity != 0) {
                    (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                        key,
                        IPoolManager.ModifyLiquidityParams({
                            tickLower: isToken0 ? position.tickLower : position.tickUpper,
                            tickUpper: isToken0 ? position.tickUpper : position.tickLower,
                            liquidityDelta: -position.liquidity.toInt128(),
                            salt: bytes32(uint256(position.salt))
                        }),
                        ""
                    );

                    slugsCallerDelta = slugsCallerDelta + callerDelta;
                    slugsFeesAccrued = slugsFeesAccrued + feesAccrued;
                }
            }

            int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
            int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);

            if (currency0Delta > 0) {
                poolManager.take(key.currency0, sender, uint256(currency0Delta));
            }

            if (currency1Delta > 0) {
                poolManager.take(key.currency1, sender, uint256(currency1Delta));
            }

            return abi.encode(slugsCallerDelta, slugsFeesAccrued);
        }

        state.lastEpoch = 1;

        (, int24 tickUpper) = _getTicksBasedOnState(0, key.tickSpacing);
        uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(tick);
        uint160 sqrtPriceCurrent = TickMath.getSqrtPriceAtTick(tick);

        // set the tickLower and tickUpper to the current tick as this is the default behavior when requiredProceeds and totalProceeds are 0
        SlugData memory lowerSlug = SlugData({ tickLower: tick, tickUpper: tick, liquidity: 0 });
        (SlugData memory upperSlug, uint256 assetRemaining) = _computeUpperSlugData(key, 0, tick, numTokensToSell);
        SlugData[] memory priceDiscoverySlugs =
            _computePriceDiscoverySlugsData(key, upperSlug, tickUpper, assetRemaining);

        Position[] memory newPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + priceDiscoverySlugs.length);

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
            newPositions[NUM_DEFAULT_SLUGS - 1 + i] = Position({
                tickLower: priceDiscoverySlugs[i].tickLower,
                tickUpper: priceDiscoverySlugs[i].tickUpper,
                liquidity: priceDiscoverySlugs[i].liquidity,
                salt: uint8(NUM_DEFAULT_SLUGS + i)
            });
        }

        _update(newPositions, sqrtPriceCurrent, sqrtPriceNext, key);

        positions[LOWER_SLUG_SALT] = newPositions[0];
        positions[UPPER_SLUG_SALT] = newPositions[1];
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            positions[bytes32(uint256(NUM_DEFAULT_SLUGS + i))] = newPositions[NUM_DEFAULT_SLUGS - 1 + i];
        }

        return new bytes(0);
    }

    /// @notice Computes the lower slug ticks and liquidity when there are insufficient proceeds
    ///         Places a single tickSpacing range at the average clearing price
    /// @param key The pool key
    /// @param totalProceeds_ The total amount of proceeds earned from selling tokens
    /// @param totalTokensSold_ The total amount of tokens sold
    function _computeLowerSlugInsufficientProceeds(
        PoolKey memory key,
        uint256 totalProceeds_,
        uint256 totalTokensSold_,
        int24 currentTick
    ) internal view returns (SlugData memory slug) {
        uint160 targetPriceX96;
        if (isToken0) {
            // Q96 Target price (not sqrtPrice)
            targetPriceX96 = _computeTargetPriceX96(totalProceeds_, totalTokensSold_);
        } else {
            // Q96 Target price (not sqrtPrice)
            targetPriceX96 = _computeTargetPriceX96(totalTokensSold_, totalProceeds_);
        }

        if (targetPriceX96 == 0) {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
            slug.liquidity = 0;
        } else {
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
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Removes the liquidity from the pool and transfers the tokens to the Airlock contract for a migration
     * @dev This function can only be called by the Airlock contract under specific conditions
     * @return sqrtPriceX96 Square root of the price of the pool in the Q96 format
     */
    function migrate(
        address recipient
    )
        external
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        if (msg.sender != initializer) revert SenderNotInitializer();

        if (!earlyExit && !(state.totalProceeds >= minimumProceeds && block.timestamp >= endingTime)) {
            revert CannotMigrate();
        }

        // close out the remaining slugs
        bytes memory data = poolManager.unlock(
            abi.encode(CallbackData({ key: poolKey, sender: recipient, tick: 0, isMigration: true }))
        );
        (BalanceDelta slugCallerDelta, BalanceDelta slugsFeesAccrued) = abi.decode(data, (BalanceDelta, BalanceDelta));
        BalanceDelta totalFeesAccrued = state.feesAccrued + slugsFeesAccrued;

        // In case some dust tokens are still left in the contract
        uint256 extraBalance0 = poolKey.currency0.balanceOfSelf();
        uint256 extraBalance1 = poolKey.currency1.balanceOfSelf();
        poolKey.currency0.transfer(recipient, extraBalance0);
        poolKey.currency1.transfer(recipient, extraBalance1);

        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        token0 = Currency.unwrap(poolKey.currency0);
        token1 = Currency.unwrap(poolKey.currency1);

        // No need to safe cast since these amounts will always be positive
        fees0 = uint128(totalFeesAccrued.amount0());
        fees1 = uint128(totalFeesAccrued.amount1());

        // In case balances were to overflow uint128, we should at least migrate uint128.max and avoid hard-revert
        uint256 _bal0 = uint256(uint128(slugCallerDelta.amount0())) + extraBalance0;
        uint256 _bal1 = uint256(uint128(slugCallerDelta.amount1())) + extraBalance1;
        balance0 = _bal0 > uint256(type(uint128).max) ? type(uint128).max : uint128(_bal0);
        balance1 = _bal1 > uint256(type(uint128).max) ? type(uint128).max : uint128(_bal1);
    }
}
