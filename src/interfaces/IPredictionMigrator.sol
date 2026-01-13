// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IPredictionMigrator
 * @notice Interface for prediction market migrator that handles entry registration and claims
 * @dev This interface defines prediction-market-specific functions. The contract also implements
 * ILiquidityMigrator for Airlock compatibility.
 */
interface IPredictionMigrator {
    // ==================== Errors ====================

    /// @notice Thrown when the oracle has not finalized the winner
    error OracleNotFinalized();

    /// @notice Thrown when attempting to register an entry that already exists for this token
    error EntryAlreadyExists();

    /// @notice Thrown when attempting to use an entryId that's already taken in the market
    error EntryIdAlreadyUsed();

    /// @notice Thrown when attempting to migrate an entry that wasn't registered
    error EntryNotRegistered();

    /// @notice Thrown when attempting to migrate an entry that was already migrated
    error AlreadyMigrated();

    /// @notice Thrown when an entry's numeraire doesn't match the market's numeraire
    error NumeraireMismatch();

    /// @notice Thrown when attempting to claim but the winning entry hasn't been migrated yet
    error WinningEntryNotMigrated();

    /// @notice Thrown when attempting to claim with a non-winning token
    error NotWinningToken();

    // ==================== Events ====================

    /// @notice Emitted when a new entry is registered for a market
    /// @param oracle The oracle address (market identifier)
    /// @param entryId Unique identifier for this entry within the market
    /// @param token The DERC20 token address for this entry
    /// @param numeraire The quote asset used for this market
    event EntryRegistered(address indexed oracle, bytes32 indexed entryId, address token, address numeraire);

    /// @notice Emitted when an entry's proceeds are migrated to the pot
    /// @param oracle The oracle address (market identifier)
    /// @param entryId Unique identifier for this entry
    /// @param token The DERC20 token address for this entry
    /// @param contribution Amount of numeraire contributed to the pot
    /// @param claimableSupply Token supply available for claims (excludes unsold tokens)
    event EntryMigrated(
        address indexed oracle, bytes32 indexed entryId, address token, uint256 contribution, uint256 claimableSupply
    );

    /// @notice Emitted when a winner claims their share of the pot
    /// @param oracle The oracle address (market identifier)
    /// @param claimer Address of the user claiming
    /// @param tokensBurned Amount of winning tokens transferred for claim
    /// @param numeraireReceived Amount of numeraire received
    event Claimed(address indexed oracle, address indexed claimer, uint256 tokensBurned, uint256 numeraireReceived);

    // ==================== Structs ====================

    /// @notice View struct for market state
    /// @param totalPot Sum of all migrated numeraire for this market
    /// @param totalClaimed Sum of all claimed numeraire from this market
    /// @param winningToken Address of the winning token (set after resolution)
    /// @param numeraire The quote asset for this market
    /// @param isResolved Whether the market has been resolved (winner determined)
    struct MarketView {
        uint256 totalPot;
        uint256 totalClaimed;
        address winningToken;
        address numeraire;
        bool isResolved;
    }

    /// @notice View struct for entry state
    /// @param token The DERC20 token address for this entry
    /// @param oracle The oracle address this entry belongs to
    /// @param entryId Unique identifier within the market
    /// @param contribution Numeraire contributed by this entry (set at migration)
    /// @param claimableSupply Token supply available for claims (set at migration)
    /// @param isMigrated Whether this entry has been migrated
    struct EntryView {
        address token;
        address oracle;
        bytes32 entryId;
        uint256 contribution;
        uint256 claimableSupply;
        bool isMigrated;
    }

    // ==================== View Functions ====================

    /// @notice Returns the market state for a given oracle
    /// @param oracle The oracle address (market identifier)
    /// @return Market state struct
    function getMarket(address oracle) external view returns (MarketView memory);

    /// @notice Returns the entry state for a given oracle and entryId
    /// @param oracle The oracle address (market identifier)
    /// @param entryId The entry identifier
    /// @return Entry state struct
    function getEntry(address oracle, bytes32 entryId) external view returns (EntryView memory);

    /// @notice Returns the entry state for a given oracle and token address
    /// @param oracle The oracle address (market identifier)
    /// @param token The entry's token address
    /// @return Entry state struct
    function getEntryByToken(address oracle, address token) external view returns (EntryView memory);

    /// @notice Preview the claim amount for a given token amount without executing
    /// @param oracle The oracle address (market identifier)
    /// @param tokenAmount Amount of winning tokens to claim with
    /// @return Amount of numeraire that would be received
    function previewClaim(address oracle, uint256 tokenAmount) external view returns (uint256);

    // ==================== State-Changing Functions ====================

    /// @notice Claims a pro-rata share of the pot by transferring winning tokens
    /// @dev Requires prior approval of tokens to this contract
    /// @param oracle The oracle address (market identifier)
    /// @param tokenAmount Amount of winning tokens to exchange for numeraire
    function claim(address oracle, uint256 tokenAmount) external;
}
