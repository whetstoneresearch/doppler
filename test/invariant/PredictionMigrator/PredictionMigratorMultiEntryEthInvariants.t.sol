// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockPredictionOracle } from "src/base/MockPredictionOracle.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import {
    PredictionMigratorMultiEntryEthInvariantHandler
} from "test/invariant/PredictionMigrator/PredictionMigratorMultiEntryEthInvariantHandler.sol";
import {
    InvariantPredictionERC20,
    PredictionMigratorAirlockHarness
} from "test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol";

contract PredictionMigratorMultiEntryEthInvariantsTest is Test {
    uint256 public constant ENTRY_SUPPLY = 1_000_000 ether;
    uint256 public constant HANDLER_ETH_BALANCE = 2_000_000_000 ether;

    PredictionMigratorAirlockHarness public airlock;
    PredictionMigrator public migrator;
    PredictionMigratorMultiEntryEthInvariantHandler public handler;
    MockPredictionOracle public oracleA;
    MockPredictionOracle public oracleB;
    InvariantPredictionERC20 public winnerTokenA;
    InvariantPredictionERC20 public loserTokenA;
    InvariantPredictionERC20 public winnerTokenB;
    InvariantPredictionERC20 public loserTokenB;

    bytes32 public winnerEntryIdA = keccak256("invariant_multi_eth_winner_a");
    bytes32 public loserEntryIdA = keccak256("invariant_multi_eth_loser_a");
    bytes32 public winnerEntryIdB = keccak256("invariant_multi_eth_winner_b");
    bytes32 public loserEntryIdB = keccak256("invariant_multi_eth_loser_b");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        airlock = new PredictionMigratorAirlockHarness();
        migrator = new PredictionMigrator(address(airlock));
        airlock.setMigrator(migrator);

        oracleA = new MockPredictionOracle();
        oracleB = new MockPredictionOracle();

        winnerTokenA = new InvariantPredictionERC20("Invariant Multi ETH Winner A", "IMEWA", ENTRY_SUPPLY);
        loserTokenA = new InvariantPredictionERC20("Invariant Multi ETH Loser A", "IMELA", ENTRY_SUPPLY);
        winnerTokenB = new InvariantPredictionERC20("Invariant Multi ETH Winner B", "IMEWB", ENTRY_SUPPLY);
        loserTokenB = new InvariantPredictionERC20("Invariant Multi ETH Loser B", "IMELB", ENTRY_SUPPLY);

        // Oracle A market: winner + loser entries sharing ETH numeraire.
        airlock.initialize(address(winnerTokenA), address(0), abi.encode(address(oracleA), winnerEntryIdA));
        airlock.initialize(address(loserTokenA), address(0), abi.encode(address(oracleA), loserEntryIdA));

        // Oracle B market: winner + loser entries sharing ETH numeraire.
        airlock.initialize(address(winnerTokenB), address(0), abi.encode(address(oracleB), winnerEntryIdB));
        airlock.initialize(address(loserTokenB), address(0), abi.encode(address(oracleB), loserEntryIdB));

        oracleA.setWinner(address(winnerTokenA));
        oracleB.setWinner(address(winnerTokenB));

        _distributeToClaimants(winnerTokenA);
        _distributeToClaimants(loserTokenA);
        _distributeToClaimants(winnerTokenB);
        _distributeToClaimants(loserTokenB);

        handler = new PredictionMigratorMultiEntryEthInvariantHandler(
            airlock,
            migrator,
            winnerTokenA,
            loserTokenA,
            winnerTokenB,
            loserTokenB,
            address(oracleA),
            address(oracleB),
            winnerEntryIdA,
            loserEntryIdA,
            winnerEntryIdB,
            loserEntryIdB,
            alice,
            bob
        );

        vm.deal(address(handler), HANDLER_ETH_BALANCE);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.migrateWinnerOracleA.selector;
        selectors[1] = handler.migrateLoserOracleA.selector;
        selectors[2] = handler.migrateWinnerOracleB.selector;
        selectors[3] = handler.migrateLoserOracleB.selector;
        selectors[4] = handler.claimOracleA.selector;
        selectors[5] = handler.claimOracleB.selector;
        selectors[6] = handler.transferWinnerOracleATokens.selector;
        selectors[7] = handler.transferLoserOracleATokens.selector;
        selectors[8] = handler.transferWinnerOracleBTokens.selector;
        selectors[9] = handler.transferLoserOracleBTokens.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(airlock));
        excludeSender(address(migrator));
        excludeSender(address(oracleA));
        excludeSender(address(oracleB));
        excludeSender(address(winnerTokenA));
        excludeSender(address(loserTokenA));
        excludeSender(address(winnerTokenB));
        excludeSender(address(loserTokenB));
        excludeSender(alice);
        excludeSender(bob);
    }

    function invariant_MarketAndEntryAccountingMatchesGhostState_MultiEntryETH() public view {
        _assertMarket(address(oracleA));
        _assertMarket(address(oracleB));
        _assertEntry(address(oracleA), winnerEntryIdA);
        _assertEntry(address(oracleA), loserEntryIdA);
        _assertEntry(address(oracleB), winnerEntryIdB);
        _assertEntry(address(oracleB), loserEntryIdB);
    }

    function invariant_GlobalEthBalanceMatchesNetGhostFlows_MultiEntryETH() public view {
        uint256 contributed = handler.ghost_totalContributed();
        uint256 claimed = handler.ghost_totalClaimed();

        assertLe(claimed, contributed, "ghost claimed exceeds ghost contributed");
        assertEq(address(migrator).balance, contributed - claimed, "migrator ETH balance does not match net ghost flow");
    }

    function invariant_GlobalGhostSumsMatchPerMarketGhostSums_MultiEntryETH() public view {
        uint256 potSum = handler.ghost_marketPot(address(oracleA)) + handler.ghost_marketPot(address(oracleB));
        uint256 claimedSum =
            handler.ghost_marketClaimed(address(oracleA)) + handler.ghost_marketClaimed(address(oracleB));

        assertEq(potSum, handler.ghost_totalContributed(), "global contributed ghost does not match per-market sum");
        assertEq(claimedSum, handler.ghost_totalClaimed(), "global claimed ghost does not match per-market sum");
    }

    function invariant_MarketPotEqualsSumOfEntryContributions_MultiEntryETH() public view {
        _assertMarketPotEqualsEntryContributions(address(oracleA), winnerEntryIdA, loserEntryIdA);
        _assertMarketPotEqualsEntryContributions(address(oracleB), winnerEntryIdB, loserEntryIdB);
    }

    function _assertMarket(address oracle) internal view {
        IPredictionMigrator.MarketView memory market = migrator.getMarket(oracle);
        assertEq(market.numeraire, address(0), "market numeraire should be ETH");
        assertEq(market.totalPot, handler.ghost_marketPot(oracle), "market totalPot mismatch");
        assertEq(market.totalClaimed, handler.ghost_marketClaimed(oracle), "market totalClaimed mismatch");
        assertLe(market.totalClaimed, market.totalPot, "market claimed exceeds pot");
    }

    function _assertEntry(address oracle, bytes32 entryId) internal view {
        IPredictionMigrator.EntryView memory entry = migrator.getEntry(oracle, entryId);
        assertEq(entry.contribution, handler.ghost_entryContribution(oracle, entryId), "entry contribution mismatch");
        assertEq(entry.isMigrated, handler.ghost_entryMigrated(oracle, entryId), "entry migrated mismatch");

        if (entry.isMigrated) {
            assertEq(entry.claimableSupply, ENTRY_SUPPLY, "claimable supply mismatch for migrated entry");
        } else {
            assertEq(entry.claimableSupply, 0, "claimable supply should be zero before migration");
        }
    }

    function _assertMarketPotEqualsEntryContributions(address oracle, bytes32 entryIdOne, bytes32 entryIdTwo) internal view {
        IPredictionMigrator.MarketView memory market = migrator.getMarket(oracle);
        IPredictionMigrator.EntryView memory entryOne = migrator.getEntry(oracle, entryIdOne);
        IPredictionMigrator.EntryView memory entryTwo = migrator.getEntry(oracle, entryIdTwo);

        assertEq(market.totalPot, entryOne.contribution + entryTwo.contribution, "market pot != sum of entry contributions");
    }

    function _distributeToClaimants(InvariantPredictionERC20 token) internal {
        token.transfer(alice, ENTRY_SUPPLY / 2);
        token.transfer(bob, ENTRY_SUPPLY / 2);
    }
}
