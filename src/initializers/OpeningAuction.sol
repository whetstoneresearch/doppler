// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import {
    IOpeningAuction,
    AuctionPhase,
    AuctionPosition,
    TickTimeState,
    OpeningAuctionConfig
} from "src/interfaces/IOpeningAuction.sol";
import { QuoterMath } from "src/libraries/QuoterMath.sol";
import { BitMath } from "@v3-core/libraries/BitMath.sol";

/// @dev Precision multiplier
uint256 constant WAD = 1e18;

/// @dev Basis points denominator
uint256 constant BPS = 10_000;


/// @title OpeningAuction
/// @notice A hook implementing a marginal price batch auction before Doppler
/// @author Whetstone Research
/// @custom:security-contact security@whetstone.cc
contract OpeningAuction is BaseHook, IOpeningAuction, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;
    using SafeTransferLib for address;

    // ============ Immutables ============

    /// @notice Address of the initializer contract
    address public immutable initializer;

    // ============ Auction Configuration ============

    /// @notice Duration of the auction in seconds
    uint256 public auctionDuration;

    /// @notice Minimum acceptable tick for bids when selling token0
    int24 public minAcceptableTickToken0;

    /// @notice Minimum acceptable tick for bids when selling token1 (tick(token0/token1))
    int24 public minAcceptableTickToken1;

    /// @notice Share of tokens for LP incentives (basis points)
    uint256 public incentiveShareBps;

    /// @notice Minimum liquidity per position (prevents dust bid griefing)
    uint128 public minLiquidity;

    /// @notice True if the asset being sold is token0
    bool public isToken0;

    /// @notice True if isToken0 has been configured (guard against misconfiguration)
    bool public isToken0Set;

    // ============ Auction Timing ============

    /// @notice Auction start timestamp
    uint256 public auctionStartTime;

    /// @notice Auction end timestamp
    uint256 public auctionEndTime;

    // ============ Auction State ============

    /// @notice Current phase of the auction
    AuctionPhase public phase;

    /// @notice Pool key for this auction
    PoolKey public poolKey;

    /// @notice True if the hook has been initialized
    bool public isInitialized;

    /// @notice Current tick of the pool
    int24 public currentTick;

    /// @notice Final clearing tick after settlement
    int24 public clearingTick;

    /// @notice Total tokens sold
    uint256 public totalTokensSold;

    /// @notice Total proceeds collected
    uint256 public totalProceeds;

    /// @notice Total tokens allocated for the auction (including incentives)
    uint256 public totalAuctionTokens;

    /// @notice Tokens reserved for LP incentives
    uint256 public incentiveTokensTotal;

    /// @notice True once migrate() has been called
    bool public isMigrated;

    // ============ Position Tracking ============

    /// @notice Next position ID to assign
    uint256 public nextPositionId;

    /// @notice Position data by ID
    mapping(uint256 positionId => AuctionPosition) internal _positions;

    /// @notice Position IDs owned by each address
    mapping(address owner => uint256[] positionIds) public ownerPositions;

    /// @notice Map position key to position ID
    mapping(bytes32 positionKey => uint256 positionId) public positionKeyToId;

    /// @notice Position IDs per tick (for lock/unlock events)
    mapping(int24 tick => uint256[] positionIds) internal tickPositions;

    /// @notice Index of position ID within tickPositions[tick]
    mapping(uint256 positionId => uint256 index) internal positionIndexInTick;

    // ============ Tick-Level Tracking (Efficient) ============

    /// @notice Liquidity at each tick level (for clearing tick estimation)
    mapping(int24 tick => uint128 liquidity) public liquidityAtTick;

    /// @notice Time tracking state per tick (for efficient incentive calculation)
    mapping(int24 tick => TickTimeState) public tickTimeStates;

    /// @notice Bitmap of active ticks (ticks with liquidity positions)
    /// @dev Uses compressed ticks (tick / tickSpacing) to reduce scan range
    mapping(int16 => uint256) internal tickBitmap;

    /// @notice Minimum active compressed tick (for bounded iteration)
    int24 internal minActiveTick;

    /// @notice Maximum active compressed tick (for bounded iteration)
    int24 internal maxActiveTick;

    /// @notice Whether any active ticks exist
    bool internal hasActiveTicks;

    /// @notice Count of active ticks (for view functions)
    uint256 internal activeTickCount;

    /// @notice Estimated clearing tick if auction settled now
    int24 public estimatedClearingTick;

    /// @notice Cached total weighted time (computed once at settlement for O(1) claims)
    uint256 public cachedTotalWeightedTimeX128;

    /// @notice Sum of reward debt * liquidity for active positions at each tick
    mapping(int24 tick => uint256) internal tickRewardDebtSumX128;

    /// @notice Harvested weighted time per position (preserved when liquidity is removed)
    /// @dev When a position is removed, its earned time is "harvested" here so it's not lost
    mapping(uint256 positionId => uint256 harvestedTimeX128) public positionHarvestedTimeX128;

    /// @notice Total harvested time across all removed positions (for settlement calculation)
    uint256 public totalHarvestedTimeX128;

    /// @notice Total incentives claimed so far
    uint256 public totalIncentivesClaimed;

    /// @notice Incentive claim deadline timestamp
    uint256 public incentivesClaimDeadline;

    /// @notice Claim window duration for incentives
    uint256 public constant INCENTIVE_CLAIM_WINDOW = 30 days;

    // ============ Constructor ============

    /// @notice Creates a new OpeningAuction hook
    /// @param poolManager_ The pool manager
    /// @param initializer_ The initializer contract address
    /// @param totalAuctionTokens_ Total tokens for the auction
    /// @param config Configuration for the auction
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config
    ) BaseHook(poolManager_) {
        if (config.auctionDuration == 0) revert InvalidAuctionDuration();
        if (config.incentiveShareBps > BPS) revert InvalidIncentiveShareBps();
        if (config.tickSpacing <= 0) revert InvalidTickSpacing();
        if (
            config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidTickSpacing();
        if (config.minLiquidity == 0) revert InvalidMinLiquidity();
        if (
            config.minAcceptableTickToken0 < TickMath.MIN_TICK
                || config.minAcceptableTickToken0 > TickMath.MAX_TICK
        ) revert InvalidMinAcceptableTick();
        if (
            config.minAcceptableTickToken1 < TickMath.MIN_TICK
                || config.minAcceptableTickToken1 > TickMath.MAX_TICK
        ) revert InvalidMinAcceptableTick();
        if (config.minAcceptableTickToken0 % config.tickSpacing != 0) revert InvalidMinAcceptableTick();
        if (config.minAcceptableTickToken1 % config.tickSpacing != 0) revert InvalidMinAcceptableTick();

        initializer = initializer_;
        totalAuctionTokens = totalAuctionTokens_;

        auctionDuration = config.auctionDuration;
        minAcceptableTickToken0 = config.minAcceptableTickToken0;
        minAcceptableTickToken1 = config.minAcceptableTickToken1;
        incentiveShareBps = config.incentiveShareBps;
        minLiquidity = config.minLiquidity;

        // Calculate incentive tokens
        incentiveTokensTotal = FullMath.mulDiv(totalAuctionTokens_, config.incentiveShareBps, BPS);

        // Start with position ID 1 (0 is reserved for "not found")
        nextPositionId = 1;
    }

    // ============ Receive ============

    /// @notice Only pool manager can send ETH
    receive() external payable {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();
    }

    // ============ External Functions ============

    /// @inheritdoc IOpeningAuction
    function positions(uint256 positionId) external view returns (AuctionPosition memory) {
        return _positions[positionId];
    }

    /// @notice Get the pool-space price limit tick enforced by swaps
    function minAcceptableTick() public view returns (int24) {
        return _auctionPriceLimitTick();
    }

    /// @inheritdoc IOpeningAuction
    function isInRange(uint256 positionId) public view returns (bool) {
        AuctionPosition memory pos = _positions[positionId];
        if (pos.owner == address(0)) return false;

        // "In range" for the auction means "would be touched by the settlement swap".
        // While the auction is Active, we use the estimated clearing tick.
        // After the auction is Settled, we use the actual clearing tick.
        int24 refTick;
        if (phase == AuctionPhase.Settled) {
            refTick = clearingTick;
        } else if (phase == AuctionPhase.Active || phase == AuctionPhase.Closed) {
            refTick = estimatedClearingTick;
        } else {
            return false;
        }

        if (isToken0) {
            // Selling token0: price moves down (tick decreases). A position is touched if we clear below its upper tick.
            return refTick < pos.tickUpper;
        } else {
            // Selling token1: price moves up (tick increases). A position is touched if we clear at or above its lower tick.
            return refTick >= pos.tickLower;
        }
    }

    /// @notice Check if a position is currently locked (backwards-compatible helper)
    /// @param positionId The position to check
    /// @return True if position would be filled if settled now
    function isPositionLocked(uint256 positionId) public view returns (bool) {
        return isInRange(positionId);
    }

    /// @notice Get a position's earned time (liquidity-weighted seconds)
    /// @param positionId The position to check
    /// @return earnedSeconds The position's earned time in liquidity-weighted seconds
    function getPositionAccumulatedTime(uint256 positionId) public view returns (uint256 earnedSeconds) {
        uint256 earnedTimeX128 = _getPositionEarnedTimeX128(positionId);
        // earnedTimeX128 = (tickAccum - debt) * posLiquidity
        // tickAccum is elapsed seconds in Q128, so >> 128 = elapsed * posLiquidity
        earnedSeconds = earnedTimeX128 >> 128;
    }

    /// @notice Get a position's earned weighted time in Q128 format (MasterChef-style)
    /// @param positionId The position to check
    /// @return earnedTimeX128 The position's earned time in Q128 format (time * liquidity)
    function _getPositionEarnedTimeX128(uint256 positionId) internal view returns (uint256 earnedTimeX128) {
        AuctionPosition memory pos = _positions[positionId];
        if (pos.owner == address(0)) return 0;

        // Start with any previously harvested time (from when liquidity was removed)
        earnedTimeX128 = positionHarvestedTimeX128[positionId];

        // Add any unharvested time still accumulating from current liquidity
        if (pos.liquidity > 0) {
            // Get the tick's current accumulator (may need real-time update if not settled)
            uint256 tickAccumulatorX128 = _getCurrentTickAccumulatorX128(pos.tickLower);

            // Position earns: (currentAccumulator - rewardDebt) * liquidity
            if (tickAccumulatorX128 > pos.rewardDebtX128) {
                earnedTimeX128 += (tickAccumulatorX128 - pos.rewardDebtX128) * uint256(pos.liquidity);
            }
        }
    }

    /// @inheritdoc IOpeningAuction
    /// @notice Calculate incentives using O(1) MasterChef-style math
    function calculateIncentives(uint256 positionId) public view returns (uint256) {
        AuctionPosition memory pos = _positions[positionId];
        if (pos.owner == address(0)) return 0;
        if (pos.hasClaimedIncentives) return 0;

        // Get position's earned weighted time (Q128)
        uint256 earnedTimeX128 = _getPositionEarnedTimeX128(positionId);
        if (earnedTimeX128 == 0) return 0;

        // Get total weighted time - use cached value if settled, otherwise compute
        uint256 totalWeightedTimeX128;
        if (phase == AuctionPhase.Settled || phase == AuctionPhase.Closed) {
            totalWeightedTimeX128 = cachedTotalWeightedTimeX128;
        } else {
            totalWeightedTimeX128 = _computeTotalWeightedTimeX128();
        }

        if (totalWeightedTimeX128 == 0) return 0;

        // incentive = (earnedTime / totalWeightedTime) * incentiveTokensTotal
        return FullMath.mulDiv(incentiveTokensTotal, earnedTimeX128, totalWeightedTimeX128);
    }

    /// @notice Get a tick's current accumulator value (with real-time update if needed)
    /// @dev Used for view functions to get accurate values before settlement
    function _getCurrentTickAccumulatorX128(int24 tick) internal view returns (uint256) {
        TickTimeState memory tickState = tickTimeStates[tick];
        uint256 accumulatorX128 = tickState.accumulatedSecondsX128;

        // If tick is in range and auction not settled, add pending time
        if (tickState.isInRange && tickState.lastUpdateTime > 0) {
            uint256 endTime = (phase == AuctionPhase.Settled || phase == AuctionPhase.Closed)
                ? auctionEndTime
                : (block.timestamp > auctionEndTime ? auctionEndTime : block.timestamp);
            if (endTime > tickState.lastUpdateTime) {
                uint256 elapsed = endTime - tickState.lastUpdateTime;
                accumulatorX128 += (elapsed << 128);
            }
        }

        return accumulatorX128;
    }

    /// @notice Compute total weighted time across all ticks (for view functions before settlement)
    /// @dev Walks the bitmap to iterate all active ticks
    function _computeTotalWeightedTimeX128() internal view returns (uint256) {
        uint256 total = totalHarvestedTimeX128;

        if (hasActiveTicks) {
            int24 iterTick = minActiveTick;
            while (iterTick <= maxActiveTick) {
                (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, maxActiveTick + 1);
                if (!found || nextCompressed > maxActiveTick) break;

                int24 nextTick = _decompressTick(nextCompressed);
                uint128 liquidity = liquidityAtTick[nextTick];
                if (liquidity > 0) {
                    uint256 tickAccumulatorX128 = _getCurrentTickAccumulatorX128(nextTick);
                    uint256 gross = tickAccumulatorX128 * uint256(liquidity);
                    uint256 debtSum = tickRewardDebtSumX128[nextTick];
                    if (gross > debtSum) {
                        total += (gross - debtSum);
                    }
                }

                iterTick = nextCompressed + 1;
            }
        }

        return total;
    }

    /// @notice Get the price limit tick enforced by swaps in pool tick space
    function _auctionPriceLimitTick() internal view returns (int24) {
        if (!isToken0Set) revert IsToken0NotSet();
        return isToken0 ? minAcceptableTickToken0 : -minAcceptableTickToken1;
    }

    /// @notice Get sqrtPrice limit for auction quotes and settlement swaps
    function _sqrtPriceLimitX96() internal view returns (uint160) {
        uint160 limit = TickMath.getSqrtPriceAtTick(_auctionPriceLimitTick());
        if (limit <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (limit >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
        return limit;
    }

    /// @notice Check if a tick violates the configured price limit
    function _tickViolatesPriceLimit(int24 tick) internal view returns (bool) {
        int24 limit = _auctionPriceLimitTick();
        return isToken0 ? (tick < limit) : (tick > limit);
    }

    /// @notice Get total accumulated time across all ticks (for external queries)
    /// @dev Returns sum of liquidity-weighted seconds across ticks
    function totalAccumulatedTime() public view returns (uint256) {
        uint256 total = 0;

        if (hasActiveTicks) {
            int24 iterTick = minActiveTick;
            while (iterTick <= maxActiveTick) {
                (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, maxActiveTick + 1);
                if (!found || nextCompressed > maxActiveTick) break;

                int24 nextTick = _decompressTick(nextCompressed);
                uint128 liquidity = liquidityAtTick[nextTick];
                if (liquidity > 0) {
                    // Convert Q128 accumulator back to liquidity-weighted seconds
                    uint256 tickAccumulatorX128 = _getCurrentTickAccumulatorX128(nextTick);
                    total += (tickAccumulatorX128 * uint256(liquidity)) >> 128;
                }

                iterTick = nextCompressed + 1;
            }
        }

        return total;
    }

    /// @inheritdoc IOpeningAuction
    function settleAuction() external nonReentrant {
        if (phase != AuctionPhase.Active) revert AuctionNotActive();
        if (block.timestamp < auctionEndTime) revert AuctionNotEnded();

        uint256 tokensToSell = totalAuctionTokens - incentiveTokensTotal - totalTokensSold;

        // Only perform price validation and swap if there are bids (active ticks with liquidity)
        // If no bids exist, auction settles with 0 tokens sold (no liquidity to absorb them)
        bool hasBids = hasActiveTicks;

        AuctionPhase oldPhase = phase;
        phase = AuctionPhase.Closed;
        emit PhaseChanged(oldPhase, AuctionPhase.Closed);

        // Finalize all tick time states at auction end
        // Time is based on being "in range" DURING the auction, not final settlement
        _finalizeAllTickTimes();

        // Execute the settlement swap only if there are bids to absorb tokens
        if (tokensToSell > 0 && hasBids) {
            _executeSettlementSwap(tokensToSell);
        }

        if (tokensToSell > 0 && hasBids) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
            int24 finalTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            clearingTick = finalTick;
        } else {
            clearingTick = _auctionPriceLimitTick();
        }

        currentTick = clearingTick;
        incentivesClaimDeadline = auctionEndTime + INCENTIVE_CLAIM_WINDOW;

        AuctionPhase closedPhase = phase;
        phase = AuctionPhase.Settled;
        emit PhaseChanged(closedPhase, AuctionPhase.Settled);

        emit AuctionSettled(clearingTick, totalTokensSold, totalProceeds);
    }

    /// @inheritdoc IOpeningAuction
    function claimIncentives(uint256 positionId) external nonReentrant {
        if (phase != AuctionPhase.Settled) revert AuctionNotSettled();
        if (!isMigrated) revert AuctionNotMigrated();
        if (block.timestamp > incentivesClaimDeadline) revert ClaimWindowEnded();

        AuctionPosition storage pos = _positions[positionId];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (pos.hasClaimedIncentives) revert AlreadyClaimed();

        uint256 amount = calculateIncentives(positionId);
        pos.hasClaimedIncentives = true;
        totalIncentivesClaimed += amount;

        if (amount > 0) {
            // Transfer incentive tokens
            Currency asset = isToken0 ? poolKey.currency0 : poolKey.currency1;
            Currency.unwrap(asset).safeTransfer(pos.owner, amount);
        }

        emit IncentivesClaimed(positionId, pos.owner, amount);
    }

    /// @inheritdoc IOpeningAuction
    function migrate(address recipient)
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
        if (phase != AuctionPhase.Settled) revert AuctionNotSettled();

        isMigrated = true;

        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(clearingTick);

        token0 = Currency.unwrap(poolKey.currency0);
        token1 = Currency.unwrap(poolKey.currency1);

        // Get balances, excluding incentive tokens that are reserved for LP claims
        // incentiveTokensTotal is denominated in the asset token (isToken0 ? token0 : token1)
        uint256 rawBalance0 = poolKey.currency0.balanceOfSelf();
        uint256 rawBalance1 = poolKey.currency1.balanceOfSelf();

        // Reserve incentive tokens for LP claims - they stay in this contract
        uint256 reservedIncentives = incentiveTokensTotal;
        if (isToken0) {
            // Asset is token0, reserve incentives from token0 balance
            uint256 transferable0 = rawBalance0 > reservedIncentives ? rawBalance0 - reservedIncentives : 0;
            balance0 = uint128(transferable0);
            balance1 = uint128(rawBalance1);
        } else {
            // Asset is token1, reserve incentives from token1 balance
            balance0 = uint128(rawBalance0);
            uint256 transferable1 = rawBalance1 > reservedIncentives ? rawBalance1 - reservedIncentives : 0;
            balance1 = uint128(transferable1);
        }

        // Transfer to recipient (excluding reserved incentives)
        if (balance0 > 0) {
            token0.safeTransfer(recipient, balance0);
        }
        if (balance1 > 0) {
            token1.safeTransfer(recipient, balance1);
        }

        // No separate fee tracking in this simple implementation
        fees0 = 0;
        fees1 = 0;
    }

    /// @inheritdoc IOpeningAuction
    function recoverIncentives(address recipient) external {
        if (msg.sender != initializer) revert SenderNotInitializer();
        if (phase != AuctionPhase.Settled) revert AuctionNotSettled();
        if (!isMigrated) revert AuctionNotMigrated();

        // Can only recover if no positions earned any time (totalWeightedTime == 0)
        // This handles the edge case where incentive tokens would otherwise be locked
        if (cachedTotalWeightedTimeX128 > 0) revert IncentivesStillClaimable();
        if (incentiveTokensTotal == 0) revert NoIncentivesToRecover();

        uint256 amount = incentiveTokensTotal;
        incentiveTokensTotal = 0; // Prevent double recovery

        Currency asset = isToken0 ? poolKey.currency0 : poolKey.currency1;
        Currency.unwrap(asset).safeTransfer(recipient, amount);

        emit IncentivesRecovered(recipient, amount);
    }

    /// @inheritdoc IOpeningAuction
    function sweepUnclaimedIncentives(address recipient) external nonReentrant {
        if (msg.sender != initializer) revert SenderNotInitializer();
        if (phase != AuctionPhase.Settled) revert AuctionNotSettled();
        if (!isMigrated) revert AuctionNotMigrated();
        if (block.timestamp <= incentivesClaimDeadline) revert ClaimWindowNotEnded();

        uint256 remaining = incentiveTokensTotal - totalIncentivesClaimed;
        if (remaining == 0) revert NoUnclaimedIncentives();

        incentiveTokensTotal = totalIncentivesClaimed;

        Currency asset = isToken0 ? poolKey.currency0 : poolKey.currency1;
        Currency.unwrap(asset).safeTransfer(recipient, remaining);

        emit IncentivesRecovered(recipient, remaining);
    }

    /// @notice Helper to derive a position ID from its key data
    function getPositionId(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        return positionKeyToId[key];
    }

    // ============ Hook Callbacks ============

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal override returns (bytes4) {
        if (sender != initializer) revert SenderNotInitializer();
        if (isInitialized) revert AlreadyInitialized();
        if (!isToken0Set) revert IsToken0NotSet();

        isInitialized = true;
        poolKey = key;

        // NOTE: isToken0 is already set by setIsToken0() called before pool.initialize()
        // Do NOT overwrite it here - that was a bug!

        // Get initial tick
        currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        currentTick = tick;
        auctionStartTime = block.timestamp;
        auctionEndTime = block.timestamp + auctionDuration;
        
        AuctionPhase oldPhase = phase;
        phase = AuctionPhase.Active;
        emit PhaseChanged(oldPhase, AuctionPhase.Active);
        
        emit AuctionStarted(
            auctionStartTime,
            auctionEndTime,
            totalAuctionTokens,
            incentiveTokensTotal
        );

        // Initialize estimated clearing tick to the pool's starting price (no positions in range initially)
        // For isToken0=true: pool starts at MAX_TICK, price moves down as tokens are sold
        // For isToken0=false: pool starts at MIN_TICK, price moves up as tokens are sold
        // Positions only enter range as bids are placed and clearing tick is recalculated
        estimatedClearingTick = isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK;

        return BaseHook.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (phase != AuctionPhase.Active) revert AuctionNotActive();

        // Block new bids after auction end time (before settlement)
        if (block.timestamp >= auctionEndTime) revert BiddingClosed();

        // Must be a single-tick position
        int24 tickSpacing = key.tickSpacing;
        if (params.tickUpper - params.tickLower != tickSpacing) {
            revert NotSingleTickPosition();
        }

        // Enforce floor (token0) or ceiling (token1) in pool tick space.
        int24 limitTick = _auctionPriceLimitTick();
        if (isToken0) {
            if (params.tickLower < limitTick) revert BidBelowMinimumPrice();
        } else {
            if (params.tickLower > limitTick) revert BidBelowMinimumPrice();
        }

        // Validate minimum liquidity to prevent dust bid griefing
        // This prevents attackers from creating many tiny positions to bloat activeTicks
        if (uint128(uint256(params.liquidityDelta)) < minLiquidity) {
            revert BidBelowMinimumLiquidity();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Track position during active auction
        if (phase == AuctionPhase.Active) {
            // Require owner address in hookData - no fallback to sender (which is typically a router)
            address owner = _decodeOwner(hookData);

            // Get liquidity (params.liquidityDelta is positive for adds)
            uint128 liquidity = uint128(uint256(params.liquidityDelta));

            // IMPORTANT: Update tick accumulator BEFORE adding liquidity
            // This ensures the new position doesn't earn rewards for time before it existed
            _updateTickAccumulator(params.tickLower);

            // Snapshot the current accumulator value for MasterChef-style reward debt
            uint256 rewardDebt = tickTimeStates[params.tickLower].accumulatedSecondsX128;

            // Create position ID
            uint256 positionId = nextPositionId++;

            bool wasInRange = tickTimeStates[params.tickLower].isInRange;

            // Store position with reward debt (MasterChef-style)
            _positions[positionId] = AuctionPosition({
                owner: owner,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidity: liquidity,
                rewardDebtX128: rewardDebt,
                hasClaimedIncentives: false
            });

            tickRewardDebtSumX128[params.tickLower] += rewardDebt * uint256(liquidity);

            // Track position key for removal lookups
            // Use owner (not sender) to prevent collision when multiple users go through same router
            bytes32 positionKey = keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
            uint256 existingId = positionKeyToId[positionKey];
            if (existingId != 0 && _positions[existingId].liquidity != 0) {
                revert PositionAlreadyExists(positionKey);
            }
            positionKeyToId[positionKey] = positionId;

            ownerPositions[owner].push(positionId);

            // Track positions by tick for lock/unlock events
            positionIndexInTick[positionId] = tickPositions[params.tickLower].length;
            tickPositions[params.tickLower].push(positionId);

            // Insert tick into activeTicks BEFORE updating liquidity
            // (because _insertTick uses liquidityAtTick==0 to detect new ticks)
            _insertTick(params.tickLower);
            liquidityAtTick[params.tickLower] += liquidity;
            
            emit LiquidityAddedToTick(params.tickLower, liquidity, liquidityAtTick[params.tickLower]);

            // Update estimated clearing tick and tick time states (efficient - only updates affected ticks)
            bool clearingTickChanged = _updateClearingTickAndTimeStates();

            // Explicitly check if the newly added tick is now in range and update its state
            // This handles the case where the tick IS the new clearing tick
            TickTimeState storage newTickState = tickTimeStates[params.tickLower];
            bool tickInRange = _wouldBeFilled(params.tickLower);
            if (tickInRange && !newTickState.isInRange) {
                newTickState.isInRange = true;
                newTickState.lastUpdateTime = block.timestamp;
            }

            if (tickInRange && (wasInRange || !clearingTickChanged)) {
                emit PositionLocked(positionId);
            }

            emit BidPlaced(positionId, owner, params.tickLower, liquidity);
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        // Allow self to remove liquidity
        if (sender == address(this)) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        if (phase == AuctionPhase.Active) {
            // Require owner address in hookData to match position key from creation
            address owner = _decodeOwner(hookData);

            // Use owner (not sender) to match position key created during add
            bytes32 positionKey = keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
            uint256 positionId = positionKeyToId[positionKey];

            if (positionId == 0) revert PositionNotFound();

            // Check on-demand if tick would be filled (O(1) - no position updates needed)
            if (_wouldBeFilled(params.tickLower)) revert PositionIsLocked();

            // Disallow partial removals - must remove full position liquidity
            // This prevents incentive accounting corruption where pos.liquidity isn't decremented
            AuctionPosition memory pos = _positions[positionId];
            uint128 liquidityToRemove = uint128(uint256(-params.liquidityDelta));
            if (liquidityToRemove != pos.liquidity) revert PartialRemovalNotAllowed();
        } else if (phase == AuctionPhase.Closed) {
            // Block removals during settlement to prevent race condition with cached denominator
            revert AuctionNotActive();
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Skip harvesting for self-initiated removals (e.g., during migration)
        if (sender == address(this)) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        if (phase == AuctionPhase.Active) {
            // Update tick accumulator before changing liquidity tracking
            // This ensures any pending time is properly accounted for
            _updateTickAccumulator(params.tickLower);

            // Decode owner from hookData to match position key from creation
            address owner = _decodeOwner(hookData);

            // Look up position to harvest its earned time
            // Use owner (not sender) to match position key created during add
            bytes32 positionKey = keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
            uint256 positionId = positionKeyToId[positionKey];

            if (positionId != 0) {
                AuctionPosition storage pos = _positions[positionId];
                if (pos.liquidity > 0) {
                    tickRewardDebtSumX128[pos.tickLower] -= pos.rewardDebtX128 * uint256(pos.liquidity);
                }

                // Harvest earned time BEFORE decrementing liquidityAtTick
                // This preserves the position's earned rewards even after removal
                _harvestPosition(positionId);

                _removePositionFromTick(params.tickLower, positionId);

                pos.liquidity = 0;
                delete positionKeyToId[positionKey];

                emit BidWithdrawn(positionId);
            }

            // Decrement liquidity tracking (liquidityDelta is negative for removals)
            uint128 liquidityRemoved = uint128(uint256(-params.liquidityDelta));
            liquidityAtTick[params.tickLower] -= liquidityRemoved;
            
            emit LiquidityRemovedFromTick(params.tickLower, liquidityRemoved, liquidityAtTick[params.tickLower]);

            // Remove tick from activeTicks when liquidity reaches 0
            // This prevents griefing attacks where attackers bloat the array with empty ticks
            if (liquidityAtTick[params.tickLower] == 0) {
                _removeTick(params.tickLower);
            }
        }

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Only allow swaps from this contract (for settlement)
        if (sender != address(this)) {
            revert SwapsNotAllowedDuringAuction();
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert CannotDonate();
    }

    // ============ Internal Functions ============

    /// @notice Decode owner address from hookData (accepts 20-byte packed or ABI-encoded address)
    function _decodeOwner(bytes calldata hookData) internal pure returns (address owner) {
        if (hookData.length == 20) {
            // Packed address (abi.encodePacked)
            assembly {
                owner := shr(96, calldataload(hookData.offset))
            }
        } else if (hookData.length >= 32) {
            // ABI-encoded address (abi.encode)
            owner = abi.decode(hookData, (address));
        } else {
            revert HookDataMissingOwner();
        }
    }

    /// @notice Check if a tick range contains the current tick
    function _isTickInRange(int24 tickLower, int24 tickUpper, int24 tick) internal pure returns (bool) {
        return tickLower <= tick && tick < tickUpper;
    }

    /// @notice Floor a tick to the nearest multiple of spacing (toward negative infinity)
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed * spacing;
    }

    /// @notice Ceil a tick to the nearest multiple of spacing (toward positive infinity)
    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) {
            compressed++;
        }
        return compressed * spacing;
    }

    /// @notice Compress a tick by tick spacing (rounding toward negative infinity)
    function _compressTick(int24 tick) internal view returns (int24) {
        int24 spacing = poolKey.tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed;
    }

    /// @notice Decompress a tick by tick spacing
    function _decompressTick(int24 compressedTick) internal view returns (int24) {
        return compressedTick * poolKey.tickSpacing;
    }

    // ============ Bitmap Helper Functions ============

    /// @notice Computes the position in the bitmap where the bit for a compressed tick lives
    /// @param tick The compressed tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function _position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick) % 256);
    }

    /// @notice Flips the bit for a given compressed tick in the bitmap
    function _flipTickCompressed(int24 tick) internal {
        (int16 wordPos, uint8 bitPos) = _position(tick);
        uint256 mask = 1 << bitPos;
        tickBitmap[wordPos] ^= mask;
    }

    /// @notice Flips the bit for a given tick in the bitmap
    /// @param tick The tick to flip
    function _flipTick(int24 tick) internal {
        _flipTickCompressed(_compressTick(tick));
    }

    /// @notice Check if a compressed tick is set in the bitmap
    function _isCompressedTickActive(int24 tick) internal view returns (bool) {
        (int16 wordPos, uint8 bitPos) = _position(tick);
        return (tickBitmap[wordPos] & (1 << bitPos)) != 0;
    }

    /// @notice Check if a tick is set in the bitmap
    /// @param tick The tick to check
    /// @return True if the tick is active (has liquidity)
    function _isTickActive(int24 tick) internal view returns (bool) {
        return _isCompressedTickActive(_compressTick(tick));
    }

    /// @notice Returns the next initialized compressed tick in the bitmap
    /// @param tick The starting compressed tick
    /// @param lte Whether to search left (less than or equal) or right (greater than)
    /// @return next The next initialized compressed tick (or tick +/- 256 if none found in word)
    /// @return initialized Whether a tick was found
    function _nextInitializedTickWithinOneWord(int24 tick, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            if (lte) {
                (int16 wordPos, uint8 bitPos) = _position(tick);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
                uint256 masked = tickBitmap[wordPos] & mask;

                initialized = masked != 0;
                next = initialized
                    ? tick - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))
                    : tick - int24(uint24(bitPos));
            } else {
                // start from the word of the next tick
                (int16 wordPos, uint8 bitPos) = _position(tick + 1);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = tickBitmap[wordPos] & mask;

                initialized = masked != 0;
                next = initialized
                    ? tick + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))
                    : tick + 1 + int24(uint24(type(uint8).max - bitPos));
            }
        }
    }

    /// @notice Find the next initialized compressed tick, searching across multiple words if needed
    /// @param tick The starting compressed tick
    /// @param lte Whether to search left (less than or equal) or right (greater than)
    /// @param boundTick The boundary compressed tick to stop searching at
    /// @return next The next initialized compressed tick, or boundTick if none found
    /// @return found Whether an initialized tick was found before the bound
    function _nextInitializedTick(int24 tick, bool lte, int24 boundTick)
        internal
        view
        returns (int24 next, bool found)
    {
        next = tick;
        while (true) {
            (int24 nextTick, bool initialized) = _nextInitializedTickWithinOneWord(next, lte);

            if (initialized) {
                return (nextTick, true);
            }

            // Check if we've passed the bound
            if (lte) {
                if (nextTick <= boundTick) return (boundTick, false);
                next = nextTick - 1; // Move to previous word
            } else {
                if (nextTick >= boundTick) return (boundTick, false);
                next = nextTick; // Already moved to next word boundary
            }
        }
    }

    /// @notice Check if a tick would be filled given the estimated clearing tick
    /// @dev During active auction, "in range" means the position would be utilized by settlement
    /// @dev A position is utilized when the clearing price enters or passes through its range
    /// @dev Position range is [tickLower, tickLower + tickSpacing)
    /// @param tick The tick to check (position's tickLower)
    /// @return True if the tick would be filled (price entered or passed through range)
    function _wouldBeFilled(int24 tick) internal view returns (bool) {
        int24 tickUpper = tick + poolKey.tickSpacing;
        if (isToken0) {
            // For isToken0=true (zeroForOne swap, price moves down from MAX_TICK):
            // Position is utilized if clearing tick is below tickUpper
            // (price moved down into or through the range)
            return estimatedClearingTick < tickUpper;
        } else {
            // For isToken0=false (!zeroForOne swap, price moves up from MIN_TICK):
            // Position is utilized if clearing tick is at or above tickLower
            // (price moved up into or through the range)
            return estimatedClearingTick >= tick;
        }
    }

    /// @notice Update tick accumulator for MasterChef-style rewards accounting
    /// @dev Must be called BEFORE liquidity changes at a tick
    /// @dev Time is capped at auctionEndTime to prevent accrual after auction ends
    /// @param tick The tick to update
    function _updateTickAccumulator(int24 tick) internal {
        TickTimeState storage tickState = tickTimeStates[tick];

        // Cap effective time at auctionEndTime to prevent post-auction accrual
        uint256 effectiveTime = block.timestamp > auctionEndTime ? auctionEndTime : block.timestamp;

        // If already finalized (lastUpdateTime >= auctionEndTime), no more updates needed
        if (tickState.lastUpdateTime >= auctionEndTime) return;

        // Only accumulate if tick is in range
        if (tickState.isInRange && tickState.lastUpdateTime > 0) {
            uint256 elapsed = effectiveTime - tickState.lastUpdateTime;
            if (elapsed > 0) {
                // Accumulate seconds in range (Q128 fixed point)
                tickState.accumulatedSecondsX128 += (elapsed << 128);
            }
        }

        tickState.lastUpdateTime = effectiveTime;
    }

    /// @notice Harvest a position's earned time before removal
    /// @dev Called when liquidity is removed to preserve earned rewards
    /// @param positionId The position to harvest
    function _harvestPosition(uint256 positionId) internal {
        AuctionPosition storage pos = _positions[positionId];
        if (pos.owner == address(0) || pos.liquidity == 0) return;

        // Calculate earned time for this position (same logic as _getPositionEarnedTimeX128)
        TickTimeState storage tickState = tickTimeStates[pos.tickLower];
        uint256 tickAccumulatorX128 = tickState.accumulatedSecondsX128;

        uint256 earnedTimeX128 = 0;
        if (tickAccumulatorX128 > pos.rewardDebtX128) {
            earnedTimeX128 = (tickAccumulatorX128 - pos.rewardDebtX128) * uint256(pos.liquidity);
        }

        if (earnedTimeX128 > 0) {
            // Store harvested time for this position
            positionHarvestedTimeX128[positionId] += earnedTimeX128;

            // Add to global total for settlement calculation
            totalHarvestedTimeX128 += earnedTimeX128;

            // Update reward debt to current accumulator (prevents double-counting if partial removal)
            pos.rewardDebtX128 = tickAccumulatorX128;
            
            emit TimeHarvested(positionId, earnedTimeX128);
        }
    }

    /// @notice Remove a position from tickPositions tracking
    function _removePositionFromTick(int24 tick, uint256 positionId) internal {
        uint256[] storage tickPositionIds = tickPositions[tick];
        if (tickPositionIds.length == 0) return;

        uint256 index = positionIndexInTick[positionId];
        if (index >= tickPositionIds.length || tickPositionIds[index] != positionId) return;

        uint256 lastIndex = tickPositionIds.length - 1;
        if (index != lastIndex) {
            uint256 swappedId = tickPositionIds[lastIndex];
            tickPositionIds[index] = swappedId;
            positionIndexInTick[swappedId] = index;
        }

        tickPositionIds.pop();
        delete positionIndexInTick[positionId];
    }

    /// @notice Insert a tick into the bitmap
    /// @dev O(1) operation - just flips a bit
    function _insertTick(int24 tick) internal {
        // O(1) existence check - if tick has liquidity, it's already in the bitmap
        if (liquidityAtTick[tick] > 0) return;

        // Flip the bit to set it
        int24 compressed = _compressTick(tick);
        _flipTickCompressed(compressed);
        activeTickCount++;

        // Update min/max bounds
        if (!hasActiveTicks) {
            minActiveTick = compressed;
            maxActiveTick = compressed;
            hasActiveTicks = true;
        } else {
            if (compressed < minActiveTick) minActiveTick = compressed;
            if (compressed > maxActiveTick) maxActiveTick = compressed;
        }
    }

    /// @notice Remove a tick from the bitmap
    /// @dev O(1) operation - just flips a bit
    function _removeTick(int24 tick) internal {
        int24 compressed = _compressTick(tick);
        if (!_isCompressedTickActive(compressed)) return;

        // Flip the bit to unset it
        _flipTickCompressed(compressed);
        activeTickCount--;

        // Update min/max bounds if needed
        if (activeTickCount == 0) {
            hasActiveTicks = false;
            // min/max become stale but that's fine - hasActiveTicks guards them
        } else if (compressed == minActiveTick) {
            // Find new minimum by walking right
            (int24 newMin, bool found) = _nextInitializedTick(compressed, false, maxActiveTick + 1);
            if (found) minActiveTick = newMin;
        } else if (compressed == maxActiveTick) {
            // Find new maximum by walking left
            (int24 newMax, bool found) = _nextInitializedTick(compressed, true, minActiveTick - 1);
            if (found) maxActiveTick = newMax;
        }
    }

    /// @notice Calculate the estimated clearing tick using view-only quoter
    /// @dev Uses QuoterMath library to simulate swap without needing unlock
    function _calculateEstimatedClearingTick() internal view returns (int24) {
        uint256 tokensToSell = totalAuctionTokens - incentiveTokensTotal;
        if (tokensToSell == 0) {
            return isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK;
        }

        // Use the view quoter to simulate the swap
        uint160 sqrtPriceLimitX96 = _sqrtPriceLimitX96();
        (,, uint160 sqrtPriceAfterX96,) = QuoterMath.quote(
            poolManager,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: isToken0,
                amountSpecified: -int256(tokensToSell), // negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        return TickMath.getTickAtSqrtPrice(sqrtPriceAfterX96);
    }

    /// @notice Update the estimated clearing tick and tick time states
    /// @dev Only updates ticks that transition in/out of range - O(k) where k = changed ticks
    /// @return changed True if the clearing tick moved
    function _updateClearingTickAndTimeStates() internal returns (bool changed) {
        int24 oldClearingTick = estimatedClearingTick;
        int24 newClearingTick = _calculateEstimatedClearingTick();
        newClearingTick = _floorToSpacing(newClearingTick, poolKey.tickSpacing);

        if (newClearingTick == oldClearingTick) return false;

        // Update estimatedClearingTick BEFORE calling _updateTickTimeStates
        // so that _wouldBeFilled uses the NEW clearing tick
        estimatedClearingTick = newClearingTick;

        // Update tick time states only for ticks that changed status
        _updateTickTimeStates(oldClearingTick, newClearingTick);

        emit EstimatedClearingTickUpdated(newClearingTick);
        return true;
    }

    /// @notice Update time states for ticks that transitioned in/out of range
    /// @param oldClearingTick Previous clearing tick
    /// @param newClearingTick New clearing tick
    /// @dev Walks ticks using bitmap between old and new boundaries
    ///      Since ticks can only enter range (not exit) due to locking, we walk forward
    function _updateTickTimeStates(int24 oldClearingTick, int24 newClearingTick) internal {
        if (!hasActiveTicks) return;

        // Determine which ticks changed state based on clearing tick movement
        // For isToken0=true: clearing tick moves DOWN, ticks enter range when clearingTick < tickUpper
        // For isToken0=false: clearing tick moves UP, ticks enter range when clearingTick >= tickLower

        int24 tickSpacing = poolKey.tickSpacing;

        if (isToken0) {
            // Price moves down (clearing tick decreases)
            // Ticks enter range when: clearingTick < tick + tickSpacing
            // Walk from ticks that just entered range (near the new clearing tick)
            if (newClearingTick < oldClearingTick) {
                // More ticks are now filled - walk ticks that entered range
                _walkTicksEnteringRange(oldClearingTick, newClearingTick, tickSpacing);
            } else if (newClearingTick > oldClearingTick) {
                // Fewer ticks are now filled - walk ticks that exited range
                _walkTicksExitingRange(oldClearingTick, newClearingTick, tickSpacing);
            }
        } else {
            // Price moves up (clearing tick increases)
            // Ticks enter range when: clearingTick >= tickLower
            if (newClearingTick > oldClearingTick) {
                // More ticks are now filled - walk ticks that entered range
                _walkTicksEnteringRange(oldClearingTick, newClearingTick, tickSpacing);
            } else if (newClearingTick < oldClearingTick) {
                // Fewer ticks are now filled - walk ticks that exited range
                _walkTicksExitingRange(oldClearingTick, newClearingTick, tickSpacing);
            }
        }
    }

    /// @notice Walk ticks that are entering the filled range and update their time states
    /// @param oldClearingTick Previous clearing tick
    /// @param newClearingTick New clearing tick  
    /// @param tickSpacing The pool's tick spacing
    function _walkTicksEnteringRange(int24 oldClearingTick, int24 newClearingTick, int24 tickSpacing) internal {
        // Find the range of ticks that just entered
        int24 startTick;
        int24 endTick;

        if (isToken0) {
            // Descending: ticks enter when clearingTick drops below tickUpper (tick + tickSpacing)
            // Walk ticks where: newClearingTick < tick + tickSpacing <= oldClearingTick
            // i.e., tick in [newClearingTick - tickSpacing + 1, oldClearingTick - tickSpacing]
            startTick = newClearingTick - tickSpacing + 1;
            endTick = oldClearingTick - tickSpacing;
        } else {
            // Ascending: ticks enter when clearingTick rises to >= tickLower
            // Walk ticks where: oldClearingTick < tick <= newClearingTick
            startTick = oldClearingTick + 1;
            endTick = newClearingTick;
        }

        int24 startAligned = _ceilToSpacing(startTick, tickSpacing);
        int24 endAligned = _floorToSpacing(endTick, tickSpacing);
        if (startAligned > endAligned) return;

        int24 startCompressed = _compressTick(startAligned);
        int24 endCompressed = _compressTick(endAligned);

        // Clamp to active tick bounds (compressed)
        if (startCompressed < minActiveTick) startCompressed = minActiveTick;
        if (endCompressed > maxActiveTick) endCompressed = maxActiveTick;
        if (startCompressed > endCompressed) return;

        // Walk through the bitmap
        int24 iterTick = startCompressed;
        while (iterTick <= endCompressed) {
            (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, endCompressed + 1);
            if (!found || nextCompressed > endCompressed) break;

            int24 nextTick = _decompressTick(nextCompressed);
            TickTimeState storage tickState = tickTimeStates[nextTick];
            tickState.lastUpdateTime = block.timestamp;
            tickState.isInRange = true;
            
            emit TickEnteredRange(nextTick, liquidityAtTick[nextTick]);

            iterTick = nextCompressed + 1;
        }
    }

    /// @notice Walk ticks that are exiting the filled range and update their time states
    /// @param oldClearingTick Previous clearing tick
    /// @param newClearingTick New clearing tick
    /// @param tickSpacing The pool's tick spacing
    function _walkTicksExitingRange(int24 oldClearingTick, int24 newClearingTick, int24 tickSpacing) internal {
        // Find the range of ticks that just exited
        int24 startTick;
        int24 endTick;

        if (isToken0) {
            // Descending: ticks exit when clearingTick rises above tickUpper
            // Walk ticks where: oldClearingTick < tick + tickSpacing <= newClearingTick
            startTick = oldClearingTick - tickSpacing + 1;
            endTick = newClearingTick - tickSpacing;
        } else {
            // Ascending: ticks exit when clearingTick drops below tickLower
            // Walk ticks where: newClearingTick < tick <= oldClearingTick
            startTick = newClearingTick + 1;
            endTick = oldClearingTick;
        }

        int24 startAligned = _ceilToSpacing(startTick, tickSpacing);
        int24 endAligned = _floorToSpacing(endTick, tickSpacing);
        if (startAligned > endAligned) return;

        int24 startCompressed = _compressTick(startAligned);
        int24 endCompressed = _compressTick(endAligned);

        // Clamp to active tick bounds (compressed)
        if (startCompressed < minActiveTick) startCompressed = minActiveTick;
        if (endCompressed > maxActiveTick) endCompressed = maxActiveTick;
        if (startCompressed > endCompressed) return;

        // Walk through the bitmap
        int24 iterTick = startCompressed;
        while (iterTick <= endCompressed) {
            (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, endCompressed + 1);
            if (!found || nextCompressed > endCompressed) break;

            int24 nextTick = _decompressTick(nextCompressed);
            TickTimeState storage tickState = tickTimeStates[nextTick];
            // Finalize accumulator before changing state
            _updateTickAccumulator(nextTick);
            tickState.isInRange = false;
            
            emit TickExitedRange(nextTick, liquidityAtTick[nextTick]);

            iterTick = nextCompressed + 1;
        }
    }

    /// @notice Finalize all tick accumulators at auction end and cache total weighted time
    /// @dev Walks the bitmap to iterate all active ticks
    function _finalizeAllTickTimes() internal {
        uint256 totalWeightedTime = totalHarvestedTimeX128;

        if (hasActiveTicks) {
            // Walk through all active ticks using the bitmap
            int24 iterTick = minActiveTick;
            while (iterTick <= maxActiveTick) {
                (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, maxActiveTick + 1);
                if (!found || nextCompressed > maxActiveTick) break;

                int24 nextTick = _decompressTick(nextCompressed);
                // Finalize each tick's accumulator
                _updateTickAccumulator(nextTick);

                // Compute this tick's contribution to total weighted time
                TickTimeState storage tickState = tickTimeStates[nextTick];
                uint128 liquidity = liquidityAtTick[nextTick];

                if (liquidity > 0) {
                    uint256 gross = tickState.accumulatedSecondsX128 * uint256(liquidity);
                    uint256 debtSum = tickRewardDebtSumX128[nextTick];
                    if (gross > debtSum) {
                        totalWeightedTime += (gross - debtSum);
                    }
                }

                iterTick = nextCompressed + 1;
            }
        }

        // Cache the total weighted time for O(1) incentive claims
        cachedTotalWeightedTimeX128 = totalWeightedTime;
    }

    /// @notice Execute the settlement swap
    function _executeSettlementSwap(uint256 amountToSell) internal {
        poolManager.unlock(abi.encode(amountToSell));
    }

    /// @notice Unlock callback for pool manager operations (settlement swap)
    /// @dev Protected by nonReentrant on settleAuction + msg.sender check
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();

        uint256 amountToSell = abi.decode(data, (uint256));

        // Execute the swap with a directional price limit
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: isToken0,
                amountSpecified: -int256(amountToSell),
                sqrtPriceLimitX96: _sqrtPriceLimitX96()
            }),
            ""
        );

        // Track tokens sold and proceeds
        if (isToken0) {
            if (delta.amount0() < 0) {
                totalTokensSold += uint256(uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                totalProceeds += uint256(uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                totalTokensSold += uint256(uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                totalProceeds += uint256(uint128(delta.amount0()));
            }
        }

        _settleDeltas(delta);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        int24 finalTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (_tickViolatesPriceLimit(finalTick)) revert SettlementPriceTooLow();

        return "";
    }

    /// @notice Settle balance deltas with pool manager
    /// @dev Delta convention: negative = we paid/sold, positive = we received
    function _settleDeltas(BalanceDelta delta) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // If amount < 0, we owe the pool (we sold/paid tokens) -> settle
        // If amount > 0, pool owes us (we bought/received tokens) -> take
        if (amount0 < 0) {
            // We owe token0 to the pool - transfer and settle
            poolManager.sync(poolKey.currency0);
            Currency.unwrap(poolKey.currency0).safeTransfer(address(poolManager), uint256(uint128(-amount0)));
            poolManager.settle();
        } else if (amount0 > 0) {
            // Pool owes us token0 - take it
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            // We owe token1 to the pool - transfer and settle
            poolManager.sync(poolKey.currency1);
            Currency.unwrap(poolKey.currency1).safeTransfer(address(poolManager), uint256(uint128(-amount1)));
            poolManager.settle();
        } else if (amount1 > 0) {
            // Pool owes us token1 - take it
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(amount1)));
        }
    }

    /// @notice Set isToken0 flag - called by initializer (ONCE, before pool.initialize)
    /// @param _isToken0 True if the asset being sold is token0, false if token1
    function setIsToken0(bool _isToken0) external {
        if (msg.sender != initializer) revert SenderNotInitializer();
        if (isInitialized) revert AlreadyInitialized();
        if (isToken0Set) revert IsToken0AlreadySet();

        isToken0 = _isToken0;
        isToken0Set = true;
    }
}
