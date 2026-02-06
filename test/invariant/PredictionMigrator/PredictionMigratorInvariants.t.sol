// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockPredictionOracle } from "src/base/MockPredictionOracle.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import {
    InvariantPredictionERC20,
    PredictionMigratorAirlockHarness,
    PredictionMigratorInvariantHandler
} from "test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol";

contract PredictionMigratorInvariantsTest is Test {
    uint256 public constant ENTRY_SUPPLY = 1_000_000 ether;
    uint256 public constant HANDLER_NUMERAIRE_BALANCE = 1_000_000_000 ether;

    PredictionMigratorAirlockHarness public airlock;
    PredictionMigrator public migrator;
    PredictionMigratorInvariantHandler public handler;
    MockPredictionOracle public oracleA;
    MockPredictionOracle public oracleB;
    InvariantPredictionERC20 public numeraire;
    InvariantPredictionERC20 public tokenA;
    InvariantPredictionERC20 public tokenB;

    bytes32 public entryIdA = keccak256("invariant_entry_a");
    bytes32 public entryIdB = keccak256("invariant_entry_b");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        airlock = new PredictionMigratorAirlockHarness();
        migrator = new PredictionMigrator(address(airlock));
        airlock.setMigrator(migrator);

        oracleA = new MockPredictionOracle();
        oracleB = new MockPredictionOracle();

        numeraire = new InvariantPredictionERC20("Invariant Numeraire", "INUM", 0);
        tokenA = new InvariantPredictionERC20("Invariant Entry A", "IENTA", ENTRY_SUPPLY);
        tokenB = new InvariantPredictionERC20("Invariant Entry B", "IENTB", ENTRY_SUPPLY);

        airlock.initialize(address(tokenA), address(numeraire), abi.encode(address(oracleA), entryIdA));
        airlock.initialize(address(tokenB), address(numeraire), abi.encode(address(oracleB), entryIdB));

        oracleA.setWinner(address(tokenA));
        oracleB.setWinner(address(tokenB));

        // All winning tokens are in user hands; unsold balance at migration is zero.
        tokenA.transfer(alice, ENTRY_SUPPLY / 2);
        tokenA.transfer(bob, ENTRY_SUPPLY / 2);
        tokenB.transfer(alice, ENTRY_SUPPLY / 2);
        tokenB.transfer(bob, ENTRY_SUPPLY / 2);

        handler = new PredictionMigratorInvariantHandler(
            airlock,
            migrator,
            numeraire,
            tokenA,
            tokenB,
            address(oracleA),
            address(oracleB),
            entryIdA,
            entryIdB,
            alice,
            bob
        );

        numeraire.mint(address(handler), HANDLER_NUMERAIRE_BALANCE);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.migrateOracleA.selector;
        selectors[1] = handler.migrateOracleB.selector;
        selectors[2] = handler.claimOracleA.selector;
        selectors[3] = handler.claimOracleB.selector;
        selectors[4] = handler.transferOracleATokens.selector;
        selectors[5] = handler.transferOracleBTokens.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(airlock));
        excludeSender(address(migrator));
        excludeSender(address(oracleA));
        excludeSender(address(oracleB));
        excludeSender(address(numeraire));
        excludeSender(address(tokenA));
        excludeSender(address(tokenB));
        excludeSender(alice);
        excludeSender(bob);
    }

    function invariant_MarketAndEntryAccountingMatchesGhostState() public view {
        _assertMarketAndEntryAccounting(address(oracleA), entryIdA);
        _assertMarketAndEntryAccounting(address(oracleB), entryIdB);
    }

    function invariant_GlobalNumeraireBalanceMatchesNetGhostFlows() public view {
        uint256 contributed = handler.ghost_totalContributed();
        uint256 claimed = handler.ghost_totalClaimed();

        assertLe(claimed, contributed, "ghost claimed exceeds ghost contributed");
        assertEq(
            numeraire.balanceOf(address(migrator)),
            contributed - claimed,
            "migrator numeraire balance does not match net ghost flow"
        );
    }

    function invariant_GlobalGhostSumsMatchPerMarketGhostSums() public view {
        uint256 potSum = handler.ghost_marketPot(address(oracleA)) + handler.ghost_marketPot(address(oracleB));
        uint256 claimedSum =
            handler.ghost_marketClaimed(address(oracleA)) + handler.ghost_marketClaimed(address(oracleB));

        assertEq(potSum, handler.ghost_totalContributed(), "global contributed ghost does not match per-market sum");
        assertEq(claimedSum, handler.ghost_totalClaimed(), "global claimed ghost does not match per-market sum");
    }

    function _assertMarketAndEntryAccounting(address oracle, bytes32 entryId) internal view {
        IPredictionMigrator.MarketView memory market = migrator.getMarket(oracle);
        IPredictionMigrator.EntryView memory entry = migrator.getEntry(oracle, entryId);

        assertEq(market.numeraire, address(numeraire), "market numeraire mismatch");
        assertEq(market.totalPot, handler.ghost_marketPot(oracle), "market totalPot mismatch");
        assertEq(market.totalClaimed, handler.ghost_marketClaimed(oracle), "market totalClaimed mismatch");
        assertLe(market.totalClaimed, market.totalPot, "market claimed exceeds pot");

        assertEq(entry.contribution, handler.ghost_entryContribution(oracle, entryId), "entry contribution mismatch");
        assertEq(entry.isMigrated, handler.ghost_entryMigrated(oracle, entryId), "entry migrated mismatch");

        if (entry.isMigrated) {
            assertEq(entry.claimableSupply, ENTRY_SUPPLY, "claimable supply mismatch for migrated entry");
        } else {
            assertEq(entry.claimableSupply, 0, "claimable supply should be zero before migration");
        }
    }
}
