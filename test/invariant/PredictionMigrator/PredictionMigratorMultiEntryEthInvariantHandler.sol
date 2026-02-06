// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import {
    InvariantPredictionERC20,
    PredictionMigratorAirlockHarness
} from "test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol";

/// @dev ETH-numeraire handler for multi-entry-per-market PredictionMigrator invariants.
contract PredictionMigratorMultiEntryEthInvariantHandler is Test {
    uint256 public constant ENTRY_SUPPLY = 1_000_000 ether;
    uint256 public constant MAX_MIGRATION_AMOUNT = 250_000 ether;

    PredictionMigratorAirlockHarness public airlock;
    PredictionMigrator public migrator;
    InvariantPredictionERC20 public winnerTokenA;
    InvariantPredictionERC20 public loserTokenA;
    InvariantPredictionERC20 public winnerTokenB;
    InvariantPredictionERC20 public loserTokenB;
    address public oracleA;
    address public oracleB;
    bytes32 public winnerEntryIdA;
    bytes32 public loserEntryIdA;
    bytes32 public winnerEntryIdB;
    bytes32 public loserEntryIdB;
    address public alice;
    address public bob;

    uint256 public ghost_totalContributed;
    uint256 public ghost_totalClaimed;
    mapping(address oracle => uint256 totalPot) public ghost_marketPot;
    mapping(address oracle => uint256 totalClaimed) public ghost_marketClaimed;
    mapping(address oracle => mapping(bytes32 entryId => bool migrated)) public ghost_entryMigrated;
    mapping(address oracle => mapping(bytes32 entryId => uint256 contribution)) public ghost_entryContribution;

    constructor(
        PredictionMigratorAirlockHarness airlock_,
        PredictionMigrator migrator_,
        InvariantPredictionERC20 winnerTokenA_,
        InvariantPredictionERC20 loserTokenA_,
        InvariantPredictionERC20 winnerTokenB_,
        InvariantPredictionERC20 loserTokenB_,
        address oracleA_,
        address oracleB_,
        bytes32 winnerEntryIdA_,
        bytes32 loserEntryIdA_,
        bytes32 winnerEntryIdB_,
        bytes32 loserEntryIdB_,
        address alice_,
        address bob_
    ) {
        airlock = airlock_;
        migrator = migrator_;
        winnerTokenA = winnerTokenA_;
        loserTokenA = loserTokenA_;
        winnerTokenB = winnerTokenB_;
        loserTokenB = loserTokenB_;
        oracleA = oracleA_;
        oracleB = oracleB_;
        winnerEntryIdA = winnerEntryIdA_;
        loserEntryIdA = loserEntryIdA_;
        winnerEntryIdB = winnerEntryIdB_;
        loserEntryIdB = loserEntryIdB_;
        alice = alice_;
        bob = bob_;
    }

    receive() external payable { }

    // =========================================================================
    // Migration Actions
    // =========================================================================

    function migrateWinnerOracleA(uint128 amountSeed, uint8 orderingSeed) external {
        _migrate(oracleA, winnerEntryIdA, winnerTokenA, amountSeed, orderingSeed);
    }

    function migrateLoserOracleA(uint128 amountSeed, uint8 orderingSeed) external {
        _migrate(oracleA, loserEntryIdA, loserTokenA, amountSeed, orderingSeed);
    }

    function migrateWinnerOracleB(uint128 amountSeed, uint8 orderingSeed) external {
        _migrate(oracleB, winnerEntryIdB, winnerTokenB, amountSeed, orderingSeed);
    }

    function migrateLoserOracleB(uint128 amountSeed, uint8 orderingSeed) external {
        _migrate(oracleB, loserEntryIdB, loserTokenB, amountSeed, orderingSeed);
    }

    function _migrate(
        address oracle,
        bytes32 entryId,
        InvariantPredictionERC20 asset,
        uint128 amountSeed,
        uint8 orderingSeed
    ) internal {
        if (ghost_entryMigrated[oracle][entryId]) return;

        uint256 amount = bound(uint256(amountSeed), 1, MAX_MIGRATION_AMOUNT);
        payable(address(migrator)).transfer(amount);

        if (orderingSeed % 2 == 0) {
            airlock.migrate(address(asset), address(0));
        } else {
            airlock.migrate(address(0), address(asset));
        }

        _recordMigration(oracle, entryId, amount);
    }

    // =========================================================================
    // Claim Actions
    // =========================================================================

    function claimOracleA(uint128 amountSeed, uint8 actorSeed) external {
        _claimWinner(oracleA, winnerEntryIdA, winnerTokenA, amountSeed, actorSeed);
    }

    function claimOracleB(uint128 amountSeed, uint8 actorSeed) external {
        _claimWinner(oracleB, winnerEntryIdB, winnerTokenB, amountSeed, actorSeed);
    }

    function _claimWinner(
        address oracle,
        bytes32 winnerEntryId,
        InvariantPredictionERC20 winningToken,
        uint128 amountSeed,
        uint8 actorSeed
    ) internal {
        if (!ghost_entryMigrated[oracle][winnerEntryId]) return;

        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 actorBalance = winningToken.balanceOf(actor);
        if (actorBalance == 0) return;

        uint256 claimTokenAmount = bound(uint256(amountSeed), 1, actorBalance);
        uint256 expectedPayout = migrator.previewClaim(oracle, claimTokenAmount);
        if (expectedPayout == 0) return;

        uint256 actorEthBefore = actor.balance;
        vm.startPrank(actor);
        winningToken.approve(address(migrator), claimTokenAmount);
        migrator.claim(oracle, claimTokenAmount);
        vm.stopPrank();

        uint256 actorEthDelta = actor.balance - actorEthBefore;
        assertEq(actorEthDelta, expectedPayout, "claim payout mismatch");

        ghost_marketClaimed[oracle] += expectedPayout;
        ghost_totalClaimed += expectedPayout;
    }

    // =========================================================================
    // Token Transfer Actions
    // =========================================================================

    function transferWinnerOracleATokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(winnerTokenA, amountSeed, fromSeed);
    }

    function transferLoserOracleATokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(loserTokenA, amountSeed, fromSeed);
    }

    function transferWinnerOracleBTokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(winnerTokenB, amountSeed, fromSeed);
    }

    function transferLoserOracleBTokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(loserTokenB, amountSeed, fromSeed);
    }

    function _transferBetweenClaimants(InvariantPredictionERC20 token, uint128 amountSeed, uint8 fromSeed) internal {
        address from = fromSeed % 2 == 0 ? alice : bob;
        address to = from == alice ? bob : alice;

        uint256 fromBalance = token.balanceOf(from);
        if (fromBalance == 0) return;

        uint256 amount = bound(uint256(amountSeed), 1, fromBalance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    // =========================================================================
    // Shared Helpers
    // =========================================================================

    function _recordMigration(address oracle, bytes32 entryId, uint256 amount) internal {
        ghost_entryMigrated[oracle][entryId] = true;
        ghost_entryContribution[oracle][entryId] = amount;
        ghost_marketPot[oracle] += amount;
        ghost_totalContributed += amount;
    }
}
