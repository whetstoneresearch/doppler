// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Phase of the opening auction
enum AuctionPhase {
    NotStarted,
    Active,
    Closed,
    Settled
}

/// @notice Data for a bid position in the opening auction
/// @param owner Address of the position owner
/// @param tickLower Lower tick of the single-tick position
/// @param tickUpper Upper tick (tickLower + tickSpacing)
/// @param liquidity Amount of liquidity
/// @param rewardDebtX128 Snapshot of tick's accumulatedSecondsX128 at position creation (MasterChef-style)
/// @param hasClaimedIncentives True if incentives already claimed
struct AuctionPosition {
    address owner;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 rewardDebtX128;
    bool hasClaimedIncentives;
}

/// @notice Time tracking state for a tick level (MasterChef-style accounting)
/// @param lastUpdateTime Last time the accumulator was updated
/// @param accumulatedSecondsX128 Accumulated in-range time (Q128 seconds)
/// @param isInRange Whether tick is currently in "would be filled" zone
struct TickTimeState {
    uint256 lastUpdateTime;
    uint256 accumulatedSecondsX128;
    bool isInRange;
}

/// @notice Configuration for the opening auction
/// @param auctionDuration Duration in seconds
/// @param minAcceptableTickToken0 Minimum acceptable price tick for token0 auctions (token1/token0)
/// @param minAcceptableTickToken1 Minimum acceptable price tick for token1 auctions, expressed as tick(token0/token1)
/// @param incentiveShareBps Percentage of tokens for LP incentives (basis points)
/// @param tickSpacing Tick spacing for the pool
/// @param fee Fee for the pool
/// @param minLiquidity Minimum liquidity per position (prevents dust bid griefing)
/// @param shareToAuctionBps Share of tokens allocated to the opening auction (basis points)
struct OpeningAuctionConfig {
    uint256 auctionDuration;
    int24 minAcceptableTickToken0;
    int24 minAcceptableTickToken1;
    uint256 incentiveShareBps;
    int24 tickSpacing;
    uint24 fee;
    uint128 minLiquidity;
    uint256 shareToAuctionBps;
}

/// @title IOpeningAuction
/// @notice Interface for the Opening Auction hook contract
interface IOpeningAuction {
    /// @notice Emitted when a bid is placed
    event BidPlaced(
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        uint128 liquidity
    );

    /// @notice Emitted when a bid is withdrawn
    event BidWithdrawn(uint256 indexed positionId);

    /// @notice Emitted when the auction settles
    event AuctionSettled(int24 clearingTick, uint256 tokensSold, uint256 proceeds);

    /// @notice Emitted when incentives are claimed
    event IncentivesClaimed(uint256 indexed positionId, address indexed owner, uint256 amount);

    /// @notice Emitted when the estimated clearing tick changes
    event EstimatedClearingTickUpdated(int24 newEstimatedClearingTick);

    /// @notice Emitted when unclaimed incentive tokens are recovered
    event IncentivesRecovered(address indexed recipient, uint256 amount);

    /// @notice Emitted when the auction starts (pool initialized)
    event AuctionStarted(
        uint256 auctionStartTime,
        uint256 auctionEndTime,
        uint256 totalAuctionTokens,
        uint256 incentiveTokensTotal
    );

    /// @notice Emitted when the auction phase changes
    event PhaseChanged(AuctionPhase indexed oldPhase, AuctionPhase indexed newPhase);

    /// @notice Emitted when a tick enters the estimated clearing range
    event TickEnteredRange(int24 indexed tick, uint128 liquidity);

    /// @notice Emitted when a tick exits the estimated clearing range
    event TickExitedRange(int24 indexed tick, uint128 liquidity);

    /// @notice Emitted when liquidity is added to a tick
    event LiquidityAddedToTick(int24 indexed tick, uint128 liquidityAdded, uint128 totalLiquidity);

    /// @notice Emitted when liquidity is removed from a tick
    event LiquidityRemovedFromTick(int24 indexed tick, uint128 liquidityRemoved, uint128 remainingLiquidity);

    /// @notice Emitted when a position's time is harvested (during removal)
    event TimeHarvested(uint256 indexed positionId, uint256 harvestedTimeX128);

    /// @notice Thrown when auction is not in the active phase
    error AuctionNotActive();

    /// @notice Thrown when auction has not ended yet
    error AuctionNotEnded();

    /// @notice Thrown when auction has not been settled
    error AuctionNotSettled();

    /// @notice Thrown when a position key is reused while still active
    error PositionAlreadyExists(bytes32 positionKey);

    /// @notice Thrown when auction has not been migrated yet
    error AuctionNotMigrated();

    /// @notice Thrown when bidding period has closed (auction ended but not yet settled)
    error BiddingClosed();

    /// @notice Thrown when the bid tick is below the minimum acceptable
    error BidBelowMinimumPrice();

    /// @notice Thrown when the bid liquidity is below the minimum required
    error BidBelowMinimumLiquidity();

    /// @notice Thrown when the position is not a single-tick position
    error NotSingleTickPosition();

    /// @notice Thrown when the position is locked and cannot be removed
    error PositionIsLocked();

    /// @notice Thrown when the position is not found
    error PositionNotFound();

    /// @notice Thrown when swaps are attempted during active auction
    error SwapsNotAllowedDuringAuction();

    /// @notice Thrown when incentives have already been claimed
    error AlreadyClaimed();

    /// @notice Thrown when caller is not the initializer
    error SenderNotInitializer();

    /// @notice Thrown when caller is not the pool manager
    error SenderNotPoolManager();

    /// @notice Thrown when the pool is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when donations are attempted
    error CannotDonate();

    /// @notice Thrown when hookData does not contain owner address
    error HookDataMissingOwner();

    /// @notice Thrown when the position manager has not been set
    error PositionManagerNotSet();

    /// @notice Thrown when caller is not the position manager
    error SenderNotPositionManager();

    /// @notice Thrown when attempting to set the position manager more than once
    error PositionManagerAlreadySet();

    /// @notice Thrown when an invalid position manager is provided
    error InvalidPositionManager();

    /// @notice Thrown when settlement clearing tick is worse than minimum acceptable
    error SettlementPriceTooLow();

    /// @notice Thrown when incentive claim window has ended
    error ClaimWindowEnded();

    /// @notice Thrown when incentive claim window has not ended
    error ClaimWindowNotEnded();

    /// @notice Thrown when no unclaimed incentives remain
    error NoUnclaimedIncentives();

    /// @notice Thrown when trying to recover incentives that are still claimable
    error IncentivesStillClaimable();

    /// @notice Thrown when no incentives available to recover
    error NoIncentivesToRecover();

    /// @notice Thrown when partial liquidity removal is attempted (only full removal allowed)
    error PartialRemovalNotAllowed();

    /// @notice Thrown when isToken0 has already been set
    error IsToken0AlreadySet();

    /// @notice Thrown when isToken0 has not been set before initialization
    error IsToken0NotSet();

    /// @notice Thrown when auctionDuration is zero
    error InvalidAuctionDuration();

    /// @notice Thrown when incentiveShareBps exceeds the basis points denominator
    error InvalidIncentiveShareBps();

    /// @notice Thrown when tickSpacing is invalid
    error InvalidTickSpacing();

    /// @notice Thrown when minLiquidity is zero
    error InvalidMinLiquidity();

    /// @notice Thrown when minAcceptableTick is out of bounds or misaligned
    error InvalidMinAcceptableTick();

    /// @notice Get the current auction phase
    function phase() external view returns (AuctionPhase);

    /// @notice Get the auction start time
    function auctionStartTime() external view returns (uint256);

    /// @notice Get the auction end time
    function auctionEndTime() external view returns (uint256);

    /// @notice Get the clearing tick after settlement
    function clearingTick() external view returns (int24);

    /// @notice Get the total tokens sold
    function totalTokensSold() external view returns (uint256);

    /// @notice Get the total proceeds
    function totalProceeds() external view returns (uint256);

    /// @notice Get the total incentive tokens available
    function incentiveTokensTotal() external view returns (uint256);

    /// @notice Get a position by ID
    function positions(uint256 positionId) external view returns (AuctionPosition memory);

    /// @notice Calculate the incentive tokens owed to a position
    /// @param positionId The position to calculate incentives for
    /// @return amount The incentive token amount
    function calculateIncentives(uint256 positionId) external view returns (uint256 amount);

    /// @notice Settle the auction by executing the clearing swap
    /// @dev Can be called by anyone after auction duration
    function settleAuction() external;

    /// @notice Claim incentive tokens for a position
    /// @param positionId The position to claim for
    function claimIncentives(uint256 positionId) external;

    /// @notice Migrate assets out after settlement
    /// @param recipient Address to receive assets
    /// @return sqrtPriceX96 Final sqrt price
    /// @return token0 Address of token0
    /// @return fees0 Fees accrued for token0
    /// @return balance0 Balance of token0
    /// @return token1 Address of token1
    /// @return fees1 Fees accrued for token1
    /// @return balance1 Balance of token1
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
        );

    /// @notice Recover incentive tokens when no positions earned time (totalWeightedTime == 0)
    /// @dev Only callable by initializer after settlement when incentives are unclaimable
    /// @param recipient Address to receive recovered tokens
    function recoverIncentives(address recipient) external;

    /// @notice Sweep unclaimed incentives after the claim window closes
    /// @param recipient Address to receive remaining incentives
    function sweepUnclaimedIncentives(address recipient) external;
}
