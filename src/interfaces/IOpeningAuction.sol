// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
/// @param rewardDebtX128 Snapshot of tick's accumulatedTimePerLiquidityX128 at position creation (MasterChef-style)
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
/// @param accumulatedTimePerLiquidityX128 Accumulated time per unit of liquidity (Q128)
/// @param isInRange Whether tick is currently in "would be filled" zone
struct TickTimeState {
    uint256 lastUpdateTime;
    uint256 accumulatedTimePerLiquidityX128;
    bool isInRange;
}

/// @notice Configuration for the opening auction
/// @param auctionDuration Duration in seconds
/// @param minAcceptableTick Minimum tick for bids (price floor)
/// @param incentiveShareBps Percentage of tokens for LP incentives (basis points)
/// @param tickSpacing Tick spacing for the pool
/// @param fee Fee for the pool
/// @param minLiquidity Minimum liquidity per position (prevents dust bid griefing)
struct OpeningAuctionConfig {
    uint256 auctionDuration;
    int24 minAcceptableTick;
    uint256 incentiveShareBps;
    int24 tickSpacing;
    uint24 fee;
    uint128 minLiquidity;
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

    /// @notice Emitted when a position becomes locked (enters range)
    event PositionLocked(uint256 indexed positionId);

    /// @notice Emitted when a position becomes unlocked (exits range)
    event PositionUnlocked(uint256 indexed positionId);

    /// @notice Emitted when a position is rolled to a new tick
    event PositionRolled(uint256 indexed positionId, int24 newTickLower);

    /// @notice Emitted when the auction settles
    event AuctionSettled(int24 clearingTick, uint256 tokensSold, uint256 proceeds);

    /// @notice Emitted when incentives are claimed
    event IncentivesClaimed(uint256 indexed positionId, address indexed owner, uint256 amount);

    /// @notice Emitted when the estimated clearing tick changes
    event EstimatedClearingTickUpdated(int24 newEstimatedClearingTick);

    /// @notice Emitted when unclaimed incentive tokens are recovered
    event IncentivesRecovered(address indexed recipient, uint256 amount);

    /// @notice Thrown when auction is not in the active phase
    error AuctionNotActive();

    /// @notice Thrown when auction has not ended yet
    error AuctionNotEnded();

    /// @notice Thrown when auction has not been settled
    error AuctionNotSettled();

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

    /// @notice Thrown when the pool is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when donations are attempted
    error CannotDonate();

    /// @notice Thrown when hookData does not contain owner address
    error HookDataMissingOwner();

    /// @notice Thrown when settlement clearing tick is worse than minimum acceptable
    error SettlementPriceTooLow();

    /// @notice Thrown when trying to recover incentives that are still claimable
    error IncentivesStillClaimable();

    /// @notice Thrown when no incentives available to recover
    error NoIncentivesToRecover();

    /// @notice Thrown when maximum number of unique ticks is exceeded
    error MaxTicksExceeded();

    /// @notice Thrown when isToken0 has already been set
    error IsToken0AlreadySet();

    /// @notice Thrown when isToken0 has not been set before initialization
    error IsToken0NotSet();

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

    /// @notice Check if a position is currently in range
    /// @param positionId The position to check
    /// @return inRange True if the position would be touched by the settlement swap
    function isInRange(uint256 positionId) external view returns (bool inRange);

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
}
