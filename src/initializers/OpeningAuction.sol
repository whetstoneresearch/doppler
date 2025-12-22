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

/// @dev Precision multiplier
uint256 constant WAD = 1e18;

/// @dev Basis points denominator
uint256 constant BPS = 10_000;


/// @title OpeningAuction
/// @notice A Uniswap V4 hook implementing a marginal price batch auction before Doppler
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

    /// @notice Minimum acceptable tick for bids
    int24 public minAcceptableTick;

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

    // ============ Position Tracking ============

    /// @notice Next position ID to assign
    uint256 public nextPositionId;

    /// @notice Position data by ID
    mapping(uint256 positionId => AuctionPosition) internal _positions;

    /// @notice Position IDs owned by each address
    mapping(address owner => uint256[] positionIds) public ownerPositions;

    /// @notice Map position key to position ID
    mapping(bytes32 positionKey => uint256 positionId) public positionKeyToId;

    // ============ Tick-Level Tracking (Efficient) ============

    /// @notice Liquidity at each tick level (for clearing tick estimation)
    mapping(int24 tick => uint128 liquidity) public liquidityAtTick;

    /// @notice Time tracking state per tick (for efficient incentive calculation)
    mapping(int24 tick => TickTimeState) public tickTimeStates;

    /// @notice List of ticks with positions (for incentive calculation)
    /// @dev Used only for iterating ticks during incentive finalization, not for clearing tick
    int24[] internal activeTicks;

    /// @notice Estimated clearing tick if auction settled now
    int24 public estimatedClearingTick;

    /// @notice Cached total weighted time (computed once at settlement for O(1) claims)
    uint256 public cachedTotalWeightedTimeX128;

    /// @notice Harvested weighted time per position (preserved when liquidity is removed)
    /// @dev When a position is removed, its earned time is "harvested" here so it's not lost
    mapping(uint256 positionId => uint256 harvestedTimeX128) public positionHarvestedTimeX128;

    /// @notice Total harvested time across all removed positions (for settlement calculation)
    uint256 public totalHarvestedTimeX128;

    // ============ Constructor ============

    /// @notice Creates a new OpeningAuction hook
    /// @param poolManager_ The Uniswap V4 pool manager
    /// @param initializer_ The initializer contract address
    /// @param totalAuctionTokens_ Total tokens for the auction
    /// @param config Configuration for the auction
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config
    ) BaseHook(poolManager_) {
        initializer = initializer_;
        totalAuctionTokens = totalAuctionTokens_;

        auctionDuration = config.auctionDuration;
        minAcceptableTick = config.minAcceptableTick;
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

    /// @inheritdoc IOpeningAuction
    function isInRange(uint256 positionId) public view returns (bool) {
        AuctionPosition memory pos = _positions[positionId];
        if (pos.owner == address(0)) return false;

        // During active auction, "in range" means "would be filled if settled now"
        if (phase == AuctionPhase.Active) {
            return _wouldBeFilled(pos.tickLower);
        }

        // After settlement, use actual tick
        return _isTickInRange(pos.tickLower, pos.tickUpper, currentTick);
    }

    /// @notice Check if a position is currently locked (backwards-compatible helper)
    /// @param positionId The position to check
    /// @return True if position would be filled if settled now
    function isPositionLocked(uint256 positionId) public view returns (bool) {
        return isInRange(positionId);
    }

    /// @notice Get a position's earned time in seconds (backwards-compatible)
    /// @param positionId The position to check
    /// @return earnedSeconds The position's earned time in seconds (proportional to liquidity share)
    function getPositionAccumulatedTime(uint256 positionId) public view returns (uint256 earnedSeconds) {
        uint256 earnedTimeX128 = _getPositionEarnedTimeX128(positionId);
        // earnedTimeX128 = (tickAccum - debt) * posLiquidity
        //                = (elapsed * 2^128 / tickLiquidity) * posLiquidity
        // So: earnedTimeX128 >> 128 = elapsed * posLiquidity / tickLiquidity
        // This gives the position's proportional share of elapsed time
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
        uint256 accumulatorX128 = tickState.accumulatedTimePerLiquidityX128;

        // If tick is in range and auction not settled, add pending time
        if (tickState.isInRange && tickState.lastUpdateTime > 0) {
            uint128 liquidity = liquidityAtTick[tick];
            if (liquidity > 0) {
                uint256 endTime = (phase == AuctionPhase.Settled || phase == AuctionPhase.Closed)
                    ? auctionEndTime
                    : block.timestamp;
                if (endTime > tickState.lastUpdateTime) {
                    uint256 elapsed = endTime - tickState.lastUpdateTime;
                    accumulatorX128 += (elapsed << 128) / liquidity;
                }
            }
        }

        return accumulatorX128;
    }

    /// @notice Compute total weighted time across all ticks (for view functions before settlement)
    /// @dev This is O(n) but only used in view functions before settlement
    function _computeTotalWeightedTimeX128() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            uint128 liquidity = liquidityAtTick[tick];

            if (liquidity > 0) {
                uint256 tickAccumulatorX128 = _getCurrentTickAccumulatorX128(tick);
                total += tickAccumulatorX128 * uint256(liquidity);
            }
        }

        // Add harvested time from positions that were removed during the auction
        total += totalHarvestedTimeX128;

        return total;
    }

    /// @notice Get total accumulated time across all ticks (for external queries)
    /// @dev Returns sum of tick times (not weighted by liquidity)
    function totalAccumulatedTime() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            uint128 liquidity = liquidityAtTick[tick];

            if (liquidity > 0) {
                // Convert Q128 accumulator back to seconds: accumulator * liquidity >> 128
                uint256 tickAccumulatorX128 = _getCurrentTickAccumulatorX128(tick);
                total += (tickAccumulatorX128 * uint256(liquidity)) >> 128;
            }
        }
        return total;
    }

    /// @inheritdoc IOpeningAuction
    function settleAuction() external nonReentrant {
        if (phase != AuctionPhase.Active) revert AuctionNotActive();
        if (block.timestamp < auctionEndTime) revert AuctionNotEnded();

        // Calculate expected clearing tick BEFORE executing swap to validate price
        uint256 tokensToSell = totalAuctionTokens - incentiveTokensTotal - totalTokensSold;

        // Only perform price validation and swap if there are bids (active ticks with liquidity)
        // If no bids exist, auction settles with 0 tokens sold (no liquidity to absorb them)
        bool hasBids = activeTicks.length > 0;

        if (tokensToSell > 0 && hasBids) {
            int24 expectedClearingTick = _calculateEstimatedClearingTick();

            // Validate expected clearing tick is not worse than minimum acceptable price
            // For isToken0=true (selling token0): clearing tick should be >= minAcceptableTick
            // For isToken0=false (selling token1): clearing tick should be <= minAcceptableTick
            if (isToken0) {
                if (expectedClearingTick < minAcceptableTick) revert SettlementPriceTooLow();
            } else {
                if (expectedClearingTick > minAcceptableTick) revert SettlementPriceTooLow();
            }
        }

        phase = AuctionPhase.Closed;

        // Finalize all tick time states at auction end
        // Time is based on being "in range" DURING the auction, not final settlement
        _finalizeAllTickTimes();

        // Execute the settlement swap only if there are bids to absorb tokens
        if (tokensToSell > 0 && hasBids) {
            _executeSettlementSwap(tokensToSell);
        }

        // Get final tick (clearing tick)
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        clearingTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        phase = AuctionPhase.Settled;

        emit AuctionSettled(clearingTick, totalTokensSold, totalProceeds);
    }

    /// @inheritdoc IOpeningAuction
    function claimIncentives(uint256 positionId) external nonReentrant {
        if (phase != AuctionPhase.Settled) revert AuctionNotSettled();

        AuctionPosition storage pos = _positions[positionId];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (pos.hasClaimedIncentives) revert AlreadyClaimed();

        uint256 amount = calculateIncentives(positionId);
        pos.hasClaimedIncentives = true;

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

        // Get current price
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

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
        phase = AuctionPhase.Active;

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
        // During active auction, validate the position
        if (phase == AuctionPhase.Active) {
            // Block new bids after auction end time (before settlement)
            if (block.timestamp >= auctionEndTime) revert BiddingClosed();

            // Must be a single-tick position
            int24 tickSpacing = key.tickSpacing;
            if (params.tickUpper - params.tickLower != tickSpacing) {
                revert NotSingleTickPosition();
            }

            // Validate tick is above minimum acceptable price
            if (isToken0) {
                if (params.tickLower < minAcceptableTick) revert BidBelowMinimumPrice();
            } else {
                if (params.tickUpper > minAcceptableTick) revert BidBelowMinimumPrice();
            }

            // Validate minimum liquidity to prevent dust bid griefing
            // This prevents attackers from creating many tiny positions to bloat activeTicks
            if (uint128(uint256(params.liquidityDelta)) < minLiquidity) {
                revert BidBelowMinimumLiquidity();
            }
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Track position during active auction
        if (phase == AuctionPhase.Active) {
            // Require owner address in hookData - no fallback to sender (which is typically a router)
            if (hookData.length < 20) revert HookDataMissingOwner();
            address owner = abi.decode(hookData, (address));

            // Get liquidity (params.liquidityDelta is positive for adds)
            uint128 liquidity = uint128(uint256(params.liquidityDelta));

            // IMPORTANT: Update tick accumulator BEFORE adding liquidity
            // This ensures the new position doesn't earn rewards for time before it existed
            _updateTickAccumulator(params.tickLower);

            // Snapshot the current accumulator value for MasterChef-style reward debt
            uint256 rewardDebt = tickTimeStates[params.tickLower].accumulatedTimePerLiquidityX128;

            // Create position ID
            uint256 positionId = nextPositionId++;

            // Store position with reward debt (MasterChef-style)
            _positions[positionId] = AuctionPosition({
                owner: owner,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidity: liquidity,
                rewardDebtX128: rewardDebt,
                hasClaimedIncentives: false
            });

            // Track position key for removal lookups
            // Use owner (not sender) to prevent collision when multiple users go through same router
            bytes32 positionKey = keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
            positionKeyToId[positionKey] = positionId;

            ownerPositions[owner].push(positionId);

            // Insert tick into activeTicks BEFORE updating liquidity
            // (because _insertTick uses liquidityAtTick==0 to detect new ticks)
            _insertTick(params.tickLower);
            liquidityAtTick[params.tickLower] += liquidity;

            // Update estimated clearing tick and tick time states (efficient - only updates affected ticks)
            _updateClearingTickAndTimeStates();

            // Explicitly check if the newly added tick is now in range and update its state
            // This handles the case where the tick IS the new clearing tick
            TickTimeState storage newTickState = tickTimeStates[params.tickLower];
            bool tickInRange = _wouldBeFilled(params.tickLower);
            if (tickInRange && !newTickState.isInRange) {
                newTickState.isInRange = true;
                newTickState.lastUpdateTime = block.timestamp;
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
            if (hookData.length < 20) revert HookDataMissingOwner();
            address owner = abi.decode(hookData, (address));

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
            address owner = abi.decode(hookData, (address));

            // Look up position to harvest its earned time
            // Use owner (not sender) to match position key created during add
            bytes32 positionKey = keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
            uint256 positionId = positionKeyToId[positionKey];

            if (positionId != 0) {
                // Harvest earned time BEFORE decrementing liquidityAtTick
                // This preserves the position's earned rewards even after removal
                _harvestPosition(positionId);
            }

            // Decrement liquidity tracking (liquidityDelta is negative for removals)
            uint128 liquidityRemoved = uint128(uint256(-params.liquidityDelta));
            liquidityAtTick[params.tickLower] -= liquidityRemoved;

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
        if (sender != address(this) && phase == AuctionPhase.Active) {
            revert SwapsNotAllowedDuringAuction();
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // NOTE: afterSwap hook removed - it was dead code because:
    // 1. External swaps are blocked by beforeSwap with SwapsNotAllowedDuringAuction
    // 2. Settlement swaps initiated by this hook via unlockCallback don't trigger afterSwap
    // The currentTick is correctly set in settleAuction() via poolManager.getSlot0()

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

    /// @notice Check if a tick range contains the current tick
    function _isTickInRange(int24 tickLower, int24 tickUpper, int24 tick) internal pure returns (bool) {
        return tickLower <= tick && tick < tickUpper;
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

        uint128 liquidity = liquidityAtTick[tick];

        // Only accumulate if tick is in range and has liquidity
        if (tickState.isInRange && liquidity > 0 && tickState.lastUpdateTime > 0) {
            uint256 elapsed = effectiveTime - tickState.lastUpdateTime;
            if (elapsed > 0) {
                // Accumulate time per unit of liquidity (Q128 fixed point)
                tickState.accumulatedTimePerLiquidityX128 += (elapsed << 128) / liquidity;
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
        uint256 tickAccumulatorX128 = tickState.accumulatedTimePerLiquidityX128;

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
        }
    }

    /// @notice Insert a tick into the sorted activeTicks array
    /// @dev For isToken0=true, ticks are sorted descending (highest first)
    ///      For isToken0=false, ticks are sorted ascending (lowest first)
    function _insertTick(int24 tick) internal {
        uint256 len = activeTicks.length;

        // O(1) existence check - if tick has liquidity, it's already in the array
        if (liquidityAtTick[tick] > 0) return;

        // Binary search for insertion point - O(log n)
        uint256 insertIdx = _findInsertionIndex(tick, len);

        // Shift elements and insert - O(n), unavoidable with dynamic arrays
        activeTicks.push(tick);
        for (uint256 i = len; i > insertIdx; i--) {
            activeTicks[i] = activeTicks[i - 1];
        }
        activeTicks[insertIdx] = tick;
    }

    /// @notice Remove a tick from the sorted activeTicks array
    /// @dev Called when liquidityAtTick reaches 0 to prevent griefing attacks
    ///      where attackers bloat the array with empty ticks
    function _removeTick(int24 tick) internal {
        uint256 len = activeTicks.length;
        if (len == 0) return;

        // Binary search to find the tick's index
        uint256 idx = _findTickIndex(tick, len);

        // If tick not found or doesn't match, nothing to remove
        if (idx >= len || activeTicks[idx] != tick) return;

        // Shift all elements after idx left by one
        for (uint256 i = idx; i < len - 1; i++) {
            activeTicks[i] = activeTicks[i + 1];
        }
        activeTicks.pop();
    }

    /// @notice Binary search to find a tick's exact index in the sorted array
    /// @dev Returns the index where tick is located, or where it would be if not found
    function _findTickIndex(int24 tick, uint256 len) internal view returns (uint256) {
        if (len == 0) return 0;

        // Cache isToken0 to avoid repeated SLOAD and reduce stack depth
        bool _isToken0 = isToken0;
        uint256 low = 0;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            int24 midTick = activeTicks[mid];

            if (midTick == tick) {
                return mid;
            }

            // Descending (isToken0=true): tick is before mid if tick > midTick
            // Ascending (isToken0=false): tick is before mid if tick < midTick
            if (_isToken0 ? tick > midTick : tick < midTick) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return low;
    }

    /// @notice Binary search to find insertion index maintaining sort order
    /// @dev For isToken0: descending (high to low), else ascending (low to high)
    function _findInsertionIndex(int24 tick, uint256 len) internal view returns (uint256) {
        if (len == 0) return 0;

        uint256 low = 0;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            int24 midTick = activeTicks[mid];

            bool shouldInsertBefore;
            if (isToken0) {
                // Descending: insert before if tick > midTick
                shouldInsertBefore = tick > midTick;
            } else {
                // Ascending: insert before if tick < midTick
                shouldInsertBefore = tick < midTick;
            }

            if (shouldInsertBefore) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return low;
    }

    /// @notice Calculate the estimated clearing tick using view-only quoter
    /// @dev Uses QuoterMath library to simulate swap without needing unlock
    function _calculateEstimatedClearingTick() internal view returns (int24) {
        uint256 tokensToSell = totalAuctionTokens - incentiveTokensTotal;
        if (tokensToSell == 0) {
            return isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK;
        }

        // Use the view quoter to simulate the swap
        (,, uint160 sqrtPriceAfterX96,) = QuoterMath.quote(
            poolManager,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: isToken0,
                amountSpecified: -int256(tokensToSell), // negative = exact input
                sqrtPriceLimitX96: isToken0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        return TickMath.getTickAtSqrtPrice(sqrtPriceAfterX96);
    }

    /// @notice Update the estimated clearing tick and tick time states
    /// @dev Only updates ticks that transition in/out of range - O(k) where k = changed ticks
    function _updateClearingTickAndTimeStates() internal {
        int24 oldClearingTick = estimatedClearingTick;
        int24 newClearingTick = _calculateEstimatedClearingTick();

        if (newClearingTick == oldClearingTick) return;

        // Update estimatedClearingTick BEFORE calling _updateTickTimeStates
        // so that _wouldBeFilled uses the NEW clearing tick
        estimatedClearingTick = newClearingTick;

        // Update tick time states only for ticks that changed status
        _updateTickTimeStates(oldClearingTick, newClearingTick);

        emit EstimatedClearingTickUpdated(newClearingTick);
    }

    /// @notice Update time states for ticks that transitioned in/out of range
    /// @param oldClearingTick Previous clearing tick
    /// @param newClearingTick New clearing tick
    /// @dev Uses binary search to find boundaries, only updates ticks that changed state
    ///      Complexity: O(log n + k) where k = number of ticks that changed state
    function _updateTickTimeStates(int24 oldClearingTick, int24 newClearingTick) internal {
        uint256 len = activeTicks.length;
        if (len == 0) return;

        // Find boundary indices using binary search
        // Boundary = index of first tick that is NOT filled
        uint256 oldBoundary = _findBoundaryIndex(oldClearingTick);
        uint256 newBoundary = _findBoundaryIndex(newClearingTick);

        if (oldBoundary == newBoundary) return; // No ticks changed state

        if (newBoundary > oldBoundary) {
            // Clearing tick moved favorably - more ticks are now filled
            // Ticks in range [oldBoundary, newBoundary) are entering the filled zone
            for (uint256 i = oldBoundary; i < newBoundary; i++) {
                int24 tick = activeTicks[i];
                TickTimeState storage tickState = tickTimeStates[tick];
                // Tick entering range - update timestamp and start tracking
                tickState.lastUpdateTime = block.timestamp;
                tickState.isInRange = true;
            }
        } else {
            // Clearing tick moved unfavorably - fewer ticks are now filled
            // Ticks in range [newBoundary, oldBoundary) are exiting the filled zone
            for (uint256 i = newBoundary; i < oldBoundary; i++) {
                int24 tick = activeTicks[i];
                TickTimeState storage tickState = tickTimeStates[tick];
                // Tick exiting range - finalize accumulator before changing state
                _updateTickAccumulator(tick);
                tickState.isInRange = false;
            }
        }
    }

    /// @notice Binary search to find the boundary index where ticks transition from filled to not filled
    /// @param clearingTick The clearing tick to use for the boundary calculation
    /// @return The index of the first tick that would NOT be filled (or length if all are filled)
    /// @dev activeTicks is sorted so filled ticks come first:
    ///      - isToken0=true: descending order, filled if clearingTick < tick + tickSpacing
    ///      - isToken0=false: ascending order, filled if clearingTick >= tick
    function _findBoundaryIndex(int24 clearingTick) internal view returns (uint256) {
        uint256 len = activeTicks.length;
        if (len == 0) return 0;

        uint256 low = 0;
        uint256 high = len;
        int24 tickSpacing = poolKey.tickSpacing;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            int24 tick = activeTicks[mid];

            bool filled;
            if (isToken0) {
                // Descending order: filled if clearingTick < tick + tickSpacing
                filled = clearingTick < tick + tickSpacing;
            } else {
                // Ascending order: filled if clearingTick >= tick
                filled = clearingTick >= tick;
            }

            if (filled) {
                // This tick is filled, boundary must be further right
                low = mid + 1;
            } else {
                // This tick is not filled, boundary is here or to the left
                high = mid;
            }
        }

        return low;
    }

    /// @notice Finalize all tick accumulators at auction end and cache total weighted time
    function _finalizeAllTickTimes() internal {
        uint256 totalWeightedTime = 0;

        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];

            // Finalize each tick's accumulator
            _updateTickAccumulator(tick);

            // Compute this tick's contribution to total weighted time
            // totalWeightedTime = sum of (accumulatedTimePerLiquidity * liquidity) for all ticks
            TickTimeState storage tickState = tickTimeStates[tick];
            uint128 liquidity = liquidityAtTick[tick];

            if (liquidity > 0) {
                // accumulatedTimePerLiquidityX128 * liquidity gives us weighted time in Q128
                totalWeightedTime += tickState.accumulatedTimePerLiquidityX128 * uint256(liquidity);
            }
        }

        // Add harvested time from positions that were removed during the auction
        // This ensures positions that earned time but were later removed still count
        totalWeightedTime += totalHarvestedTimeX128;

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

        // TOCTOU fix: Use minAcceptableTick as price limit instead of extreme values
        // This ensures the settlement swap cannot execute at a worse price than validated
        // in settleAuction() even if liquidity changes between validation and execution
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(minAcceptableTick);

        // Execute the swap with price limit based on minAcceptableTick
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: isToken0,
                amountSpecified: -int256(amountToSell),
                sqrtPriceLimitX96: sqrtPriceLimitX96
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

        return "";
    }

    /// @notice Settle balance deltas with pool manager
    /// @dev V4 delta convention: negative = we paid/sold, positive = we received
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
