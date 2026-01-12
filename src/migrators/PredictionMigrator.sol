// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { IPredictionOracle } from "src/interfaces/IPredictionOracle.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/**
 * @title PredictionMigrator
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Handles registration of prediction market entries at creation time and
 * distribution of proceeds to winners at claim time.
 * @dev Implements both ILiquidityMigrator (for Airlock compatibility) and
 * IPredictionMigrator (for prediction-market-specific functions).
 *
 * Key responsibilities:
 * 1. Register oracle + entryId at creation time (via initialize())
 * 2. Receive numeraire from Airlock during migration
 * 3. Track total pot per market (oracle)
 * 4. Enforce numeraire consistency within a market
 * 5. Verify oracle resolution before allowing migration
 * 6. Process claims for winning token holders
 */
contract PredictionMigrator is ILiquidityMigrator, IPredictionMigrator, ImmutableAirlock, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    // ==================== Storage ====================

    /// @dev Internal market state
    struct MarketState {
        uint256 totalPot;
        address winningToken;
        address numeraire;
        bool isResolved;
    }

    /// @dev Internal entry state
    struct EntryState {
        address token;
        address oracle;
        bytes32 entryId;
        uint256 contribution;
        uint256 claimableSupply;
        bool isMigrated;
    }

    /// @notice Market-level state keyed by oracle address
    mapping(address oracle => MarketState) internal _markets;

    /// @notice Entry-level state keyed by oracle and entryId
    mapping(address oracle => mapping(bytes32 entryId => EntryState)) internal _entries;

    /// @notice Token to oracle lookup (set at initialize, used at migrate)
    mapping(address token => address oracle) internal _tokenToOracle;

    /// @notice Token to entryId lookup (set at initialize, used at migrate)
    mapping(address token => bytes32 entryId) internal _tokenToEntryId;

    /// @notice Reverse lookup within market: oracle => token => entryId
    mapping(address oracle => mapping(address token => bytes32 entryId)) internal _marketTokenToEntry;

    // ==================== Constructor ====================

    /// @notice Anyone can send ETH to this contract (for ETH numeraire migrations)
    receive() external payable { }

    /// @param airlock_ Address of the Airlock contract
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    // ==================== ILiquidityMigrator Implementation ====================

    /// @inheritdoc ILiquidityMigrator
    /// @notice Registers a new entry for a prediction market
    /// @dev Called by Airlock during create(). Decodes oracle and entryId from data.
    /// @param asset The DERC20 token address for this entry
    /// @param numeraire The quote asset (must match existing entries in the same market)
    /// @param data ABI-encoded (address oracle, bytes32 entryId)
    /// @return Always returns address(0) since prediction markets don't have a migration pool
    function initialize(address asset, address numeraire, bytes calldata data) external onlyAirlock returns (address) {
        // Decode oracle and entryId from data
        (address oracle, bytes32 entryId) = abi.decode(data, (address, bytes32));

        // Verify entry uniqueness within this market (by token)
        require(_marketTokenToEntry[oracle][asset] == bytes32(0), EntryAlreadyExists());

        // Verify entryId uniqueness within this market
        require(_entries[oracle][entryId].token == address(0), EntryIdAlreadyUsed());

        // Check/set market numeraire (first entry sets it, subsequent must match)
        MarketState storage market = _markets[oracle];
        if (market.numeraire == address(0)) {
            market.numeraire = numeraire;
        } else {
            require(market.numeraire == numeraire, NumeraireMismatch());
        }

        // Register entry (not yet migrated)
        _tokenToOracle[asset] = oracle;
        _tokenToEntryId[asset] = entryId;
        _marketTokenToEntry[oracle][asset] = entryId;

        _entries[oracle][entryId] = EntryState({
            token: asset, oracle: oracle, entryId: entryId, contribution: 0, claimableSupply: 0, isMigrated: false
        });

        emit EntryRegistered(oracle, entryId, asset, numeraire);

        // Return value not used for prediction markets
        return address(0);
    }

    /// @inheritdoc ILiquidityMigrator
    /// @notice Migrates an entry's proceeds to the pot after oracle finalization
    /// @dev Called by Airlock during migrate(). Airlock transfers tokens before calling.
    /// @param token0 First token of the pair
    /// @param token1 Second token of the pair
    /// @return Always returns 0 (liquidity not applicable for prediction markets)
    function migrate(uint160, address token0, address token1, address) external payable onlyAirlock returns (uint256) {
        // Determine which token is the asset (the one we registered)
        address asset = _tokenToOracle[token0] != address(0) ? token0 : token1;
        address numeraire = asset == token0 ? token1 : token0;

        address oracle = _tokenToOracle[asset];
        bytes32 entryId = _tokenToEntryId[asset];

        require(oracle != address(0), EntryNotRegistered());

        EntryState storage entry = _entries[oracle][entryId];
        require(!entry.isMigrated, AlreadyMigrated());

        // Check oracle is finalized
        (, bool isFinalized) = IPredictionOracle(oracle).getWinner(oracle);
        require(isFinalized, OracleNotFinalized());

        MarketState storage market = _markets[oracle];

        // Get numeraire amount being migrated (transferred by Airlock before this call)
        // Note: Airlock deducts fees before transfer, so this is post-fee amount
        uint256 numeraireAmount = _getNumeraireBalance(numeraire) - market.totalPot;

        // Get asset tokens transferred to us (unsold tokens from pool)
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));

        // Calculate claimable supply BEFORE pseudo-burning
        // claimableSupply = tokens in user hands = totalSupply - unsold tokens we hold
        uint256 claimableSupply = IERC20(asset).totalSupply() - assetBalance;

        // Pseudo-burn unsold tokens by sending to dead address
        // Note: OpenZeppelin ERC20 reverts on transfer to address(0), so we use DEAD_ADDRESS
        if (assetBalance > 0) {
            ERC20(asset).safeTransfer(DEAD_ADDRESS, assetBalance);
        }

        // Update entry
        entry.contribution = numeraireAmount;
        entry.claimableSupply = claimableSupply;
        entry.isMigrated = true;

        // Update market pot
        market.totalPot += numeraireAmount;

        emit EntryMigrated(oracle, entryId, asset, numeraireAmount, claimableSupply);

        // Return value not used for prediction markets
        return 0;
    }

    // ==================== IPredictionMigrator Implementation ====================

    /// @inheritdoc IPredictionMigrator
    function claim(address oracle, uint256 tokenAmount) external nonReentrant {
        MarketState storage market = _markets[oracle];

        // Lazy resolution check
        if (!market.isResolved) {
            (address winner, bool isFinalized) = IPredictionOracle(oracle).getWinner(oracle);
            require(isFinalized, OracleNotFinalized());
            market.winningToken = winner;
            market.isResolved = true;
        }

        address winningToken = market.winningToken;
        bytes32 winningEntryId = _marketTokenToEntry[oracle][winningToken];
        EntryState storage winningEntry = _entries[oracle][winningEntryId];

        require(winningEntry.isMigrated, WinningEntryNotMigrated());

        // Calculate claim amount
        // claimAmount = (tokenAmount / claimableSupply) * totalPot
        uint256 claimAmount = (tokenAmount * market.totalPot) / winningEntry.claimableSupply;

        // Transfer tokens from user to this contract (requires prior approval)
        // Tokens are held here permanently (pseudo-burned)
        ERC20(winningToken).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Transfer numeraire to user
        _transferNumeraire(market.numeraire, msg.sender, claimAmount);

        emit Claimed(oracle, msg.sender, tokenAmount, claimAmount);
    }

    /// @inheritdoc IPredictionMigrator
    function getMarket(address oracle) external view returns (MarketView memory) {
        MarketState storage market = _markets[oracle];
        return MarketView({
            totalPot: market.totalPot,
            winningToken: market.winningToken,
            numeraire: market.numeraire,
            isResolved: market.isResolved
        });
    }

    /// @inheritdoc IPredictionMigrator
    function getEntry(address oracle, bytes32 entryId) external view returns (EntryView memory) {
        EntryState storage entry = _entries[oracle][entryId];
        return EntryView({
            token: entry.token,
            oracle: entry.oracle,
            entryId: entry.entryId,
            contribution: entry.contribution,
            claimableSupply: entry.claimableSupply,
            isMigrated: entry.isMigrated
        });
    }

    /// @inheritdoc IPredictionMigrator
    function getEntryByToken(address oracle, address token) external view returns (EntryView memory) {
        bytes32 entryId = _marketTokenToEntry[oracle][token];
        EntryState storage entry = _entries[oracle][entryId];
        return EntryView({
            token: entry.token,
            oracle: entry.oracle,
            entryId: entry.entryId,
            contribution: entry.contribution,
            claimableSupply: entry.claimableSupply,
            isMigrated: entry.isMigrated
        });
    }

    /// @inheritdoc IPredictionMigrator
    function previewClaim(address oracle, uint256 tokenAmount) external view returns (uint256) {
        MarketState storage market = _markets[oracle];

        address winningToken;
        if (market.isResolved) {
            winningToken = market.winningToken;
        } else {
            (winningToken,) = IPredictionOracle(oracle).getWinner(oracle);
        }

        bytes32 winningEntryId = _marketTokenToEntry[oracle][winningToken];
        EntryState storage winningEntry = _entries[oracle][winningEntryId];

        if (winningEntry.claimableSupply == 0) {
            return 0;
        }

        return (tokenAmount * market.totalPot) / winningEntry.claimableSupply;
    }

    // ==================== Internal Helpers ====================

    /// @dev Helper to get numeraire balance, handling ETH case
    function _getNumeraireBalance(address numeraire) internal view returns (uint256) {
        if (numeraire == address(0)) {
            return address(this).balance;
        }
        return IERC20(numeraire).balanceOf(address(this));
    }

    /// @dev Helper to transfer numeraire, handling ETH case
    function _transferNumeraire(address numeraire, address to, uint256 amount) internal {
        if (numeraire == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(numeraire).safeTransfer(to, amount);
        }
    }
}
