// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockPredictionOracle } from "src/base/MockPredictionOracle.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import {
    PredictionMigratorEthInvariantHandler
} from "test/invariant/PredictionMigrator/PredictionMigratorEthInvariantHandler.sol";
import {
    InvariantPredictionERC20,
    PredictionMigratorAirlockHarness
} from "test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol";

contract PredictionMigratorEthInvariantsTest is Test {
    uint256 public constant ENTRY_SUPPLY = 1_000_000 ether;
    uint256 public constant HANDLER_ETH_BALANCE = 1_000_000_000 ether;

    PredictionMigratorAirlockHarness public airlock;
    PredictionMigrator public migrator;
    PredictionMigratorEthInvariantHandler public handler;
    MockPredictionOracle public oracleA;
    MockPredictionOracle public oracleB;
    InvariantPredictionERC20 public tokenA;
    InvariantPredictionERC20 public tokenB;

    bytes32 public entryIdA = keccak256("invariant_eth_entry_a");
    bytes32 public entryIdB = keccak256("invariant_eth_entry_b");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        airlock = new PredictionMigratorAirlockHarness();
        migrator = new PredictionMigrator(address(airlock));
        airlock.setMigrator(migrator);

        oracleA = new MockPredictionOracle();
        oracleB = new MockPredictionOracle();

        tokenA = new InvariantPredictionERC20("Invariant ETH Entry A", "IETHA", ENTRY_SUPPLY);
        tokenB = new InvariantPredictionERC20("Invariant ETH Entry B", "IETHB", ENTRY_SUPPLY);

        airlock.initialize(address(tokenA), address(0), abi.encode(address(oracleA), entryIdA));
        airlock.initialize(address(tokenB), address(0), abi.encode(address(oracleB), entryIdB));

        oracleA.setWinner(address(tokenA));
        oracleB.setWinner(address(tokenB));

        // All winning tokens are in user hands; unsold balance at migration is zero.
        tokenA.transfer(alice, ENTRY_SUPPLY / 2);
        tokenA.transfer(bob, ENTRY_SUPPLY / 2);
        tokenB.transfer(alice, ENTRY_SUPPLY / 2);
        tokenB.transfer(bob, ENTRY_SUPPLY / 2);

        handler = new PredictionMigratorEthInvariantHandler(
            airlock, migrator, tokenA, tokenB, address(oracleA), address(oracleB), entryIdA, entryIdB, alice, bob
        );

        vm.deal(address(handler), HANDLER_ETH_BALANCE);

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
        excludeSender(address(tokenA));
        excludeSender(address(tokenB));
        excludeSender(alice);
        excludeSender(bob);
    }

    function invariant_MarketAndEntryAccountingMatchesGhostState_ETH() public view {
        _assertMarketAndEntryAccounting(address(oracleA), entryIdA);
        _assertMarketAndEntryAccounting(address(oracleB), entryIdB);
    }

    function invariant_GlobalEthBalanceMatchesNetGhostFlows() public view {
        uint256 contributed = handler.ghost_totalContributed();
        uint256 claimed = handler.ghost_totalClaimed();

        assertLe(claimed, contributed, "ghost claimed exceeds ghost contributed");
        assertEq(address(migrator).balance, contributed - claimed, "migrator ETH balance does not match net ghost flow");
    }

    function invariant_GlobalGhostSumsMatchPerMarketGhostSums_ETH() public view {
        uint256 potSum = handler.ghost_marketPot(address(oracleA)) + handler.ghost_marketPot(address(oracleB));
        uint256 claimedSum =
            handler.ghost_marketClaimed(address(oracleA)) + handler.ghost_marketClaimed(address(oracleB));

        assertEq(potSum, handler.ghost_totalContributed(), "global contributed ghost does not match per-market sum");
        assertEq(claimedSum, handler.ghost_totalClaimed(), "global claimed ghost does not match per-market sum");
    }

    function _assertMarketAndEntryAccounting(address oracle, bytes32 entryId) internal view {
        IPredictionMigrator.MarketView memory market = migrator.getMarket(oracle);
        IPredictionMigrator.EntryView memory entry = migrator.getEntry(oracle, entryId);

        assertEq(market.numeraire, address(0), "market numeraire should be ETH");
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
