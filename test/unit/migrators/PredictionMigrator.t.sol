// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { AlreadyFinalized, MockPredictionOracle, OnlyOwner } from "src/base/MockPredictionOracle.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { IPredictionOracle } from "src/interfaces/IPredictionOracle.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/// @dev Simple ERC20 mock for testing with totalSupply support
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract PredictionMigratorTest is Test {
    PredictionMigrator public migrator;
    MockPredictionOracle public oracle;

    address public airlock;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public numeraire;

    bytes32 public entryIdA;
    bytes32 public entryIdB;

    function setUp() public {
        airlock = address(this); // Test contract acts as Airlock
        migrator = new PredictionMigrator(airlock);
        oracle = new MockPredictionOracle();

        tokenA = new MockERC20("Token A", "TKNA", 1_000_000 ether);
        tokenB = new MockERC20("Token B", "TKNB", 1_000_000 ether);
        numeraire = new MockERC20("Numeraire", "NUM", 1_000_000 ether);

        entryIdA = keccak256(abi.encodePacked("entry_a"));
        entryIdB = keccak256(abi.encodePacked("entry_b"));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                  constructor()                                   */
    /* -------------------------------------------------------------------------------- */

    function test_constructor_SetsAirlock() public view {
        assertEq(address(migrator.airlock()), airlock);
    }

    function test_receive_AcceptsETH() public {
        deal(address(this), 1 ether);
        payable(address(migrator)).transfer(1 ether);
        assertEq(address(migrator).balance, 1 ether);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                  initialize()                                    */
    /* -------------------------------------------------------------------------------- */

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(alice);
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
    }

    function test_initialize_RegistersEntry() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        IPredictionMigrator.EntryView memory entry = migrator.getEntry(address(oracle), entryIdA);
        assertEq(entry.token, address(tokenA));
        assertEq(entry.oracle, address(oracle));
        assertEq(entry.entryId, entryIdA);
        assertEq(entry.contribution, 0);
        assertEq(entry.claimableSupply, 0);
        assertFalse(entry.isMigrated);
    }

    function test_initialize_SetsMarketNumeraireOnFirstEntry() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(market.numeraire, address(numeraire));
        assertEq(market.totalPot, 0);
        assertFalse(market.isResolved);
    }

    function test_initialize_AllowsMultipleEntriesWithSameNumeraire() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));

        IPredictionMigrator.EntryView memory entryA = migrator.getEntry(address(oracle), entryIdA);
        IPredictionMigrator.EntryView memory entryB = migrator.getEntry(address(oracle), entryIdB);

        assertEq(entryA.token, address(tokenA));
        assertEq(entryB.token, address(tokenB));
    }

    function test_initialize_RevertsOnDuplicateToken() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        vm.expectRevert(IPredictionMigrator.EntryAlreadyExists.selector);
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdB));
    }

    function test_initialize_RevertsOnDuplicateEntryId() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        vm.expectRevert(IPredictionMigrator.EntryIdAlreadyUsed.selector);
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdA));
    }

    function test_initialize_RevertsOnNumeraireMismatch() public {
        MockERC20 otherNumeraire = new MockERC20("Other", "OTH", 1_000_000 ether);

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        vm.expectRevert(IPredictionMigrator.NumeraireMismatch.selector);
        migrator.initialize(address(tokenB), address(otherNumeraire), abi.encode(address(oracle), entryIdB));
    }

    function test_initialize_ReturnsZeroAddress() public {
        address pool = migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        assertEq(pool, address(0));
    }

    function test_initialize_EmitsEntryRegistered() public {
        vm.expectEmit(true, true, false, true);
        emit IPredictionMigrator.EntryRegistered(address(oracle), entryIdA, address(tokenA), address(numeraire));

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                   migrate()                                      */
    /* -------------------------------------------------------------------------------- */

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(alice);
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));
    }

    function test_migrate_RevertsWhenEntryNotRegistered() public {
        oracle.setWinner(address(tokenA));

        vm.expectRevert(IPredictionMigrator.EntryNotRegistered.selector);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));
    }

    function test_migrate_RevertsWhenOracleNotFinalized() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        // Oracle not finalized yet
        vm.expectRevert(IPredictionMigrator.OracleNotFinalized.selector);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));
    }

    function test_migrate_RevertsWhenAlreadyMigrated() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // Transfer tokens to migrator (simulating Airlock behavior)
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 500_000 ether); // unsold tokens

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        vm.expectRevert(IPredictionMigrator.AlreadyMigrated.selector);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));
    }

    function test_migrate_UpdatesEntryState() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // Transfer tokens to migrator (simulating Airlock behavior)
        uint256 numeraireAmount = 100 ether;
        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), numeraireAmount);
        tokenA.transfer(address(migrator), unsoldTokens);

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        IPredictionMigrator.EntryView memory entry = migrator.getEntry(address(oracle), entryIdA);
        assertEq(entry.contribution, numeraireAmount);
        assertEq(entry.claimableSupply, 1_000_000 ether - unsoldTokens); // totalSupply - unsold
        assertTrue(entry.isMigrated);
    }

    function test_migrate_UpdatesMarketPot() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(market.totalPot, 100 ether);
    }

    function test_migrate_PseudoBurnsUnsoldTokens() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), unsoldTokens);

        uint256 deadBalanceBefore = tokenA.balanceOf(DEAD_ADDRESS);

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        assertEq(tokenA.balanceOf(DEAD_ADDRESS), deadBalanceBefore + unsoldTokens);
        assertEq(tokenA.balanceOf(address(migrator)), 0);
    }

    function test_migrate_HandlesZeroUnsoldTokens() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // All tokens sold, only numeraire transferred
        numeraire.transfer(address(migrator), 100 ether);

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        IPredictionMigrator.EntryView memory entry = migrator.getEntry(address(oracle), entryIdA);
        assertEq(entry.claimableSupply, 1_000_000 ether); // All tokens claimable
    }

    function test_migrate_EmitsEntryMigrated() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        uint256 numeraireAmount = 100 ether;
        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), numeraireAmount);
        tokenA.transfer(address(migrator), unsoldTokens);

        vm.expectEmit(true, true, false, true);
        emit IPredictionMigrator.EntryMigrated(
            address(oracle), entryIdA, address(tokenA), numeraireAmount, 1_000_000 ether - unsoldTokens
        );

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));
    }

    function test_migrate_AggregatesPotAcrossMultipleEntries() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));
        oracle.setWinner(address(tokenA));

        // Migrate first entry
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Migrate second entry
        numeraire.transfer(address(migrator), 50 ether);
        tokenB.transfer(address(migrator), 600_000 ether);
        migrator.migrate(0, address(tokenB), address(numeraire), address(0));

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(market.totalPot, 150 ether); // 100 + 50
    }

    /* -------------------------------------------------------------------------------- */
    /*                                    claim()                                       */
    /* -------------------------------------------------------------------------------- */

    function _setupWinningEntry() internal returns (uint256 claimableSupply) {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));
        oracle.setWinner(address(tokenA));

        // Migrate winning entry
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Migrate losing entry (adds to pot)
        numeraire.transfer(address(migrator), 50 ether);
        tokenB.transfer(address(migrator), 600_000 ether);
        migrator.migrate(0, address(tokenB), address(numeraire), address(0));

        claimableSupply = 600_000 ether; // tokenA totalSupply - unsold
    }

    function test_claim_RevertsWhenOracleNotFinalized() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        // Oracle not finalized

        vm.expectRevert(IPredictionMigrator.OracleNotFinalized.selector);
        migrator.claim(address(oracle), 1 ether);
    }

    function test_claim_RevertsWhenWinningEntryNotMigrated() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // Entry not migrated yet
        tokenA.transfer(alice, 100 ether);
        vm.startPrank(alice);
        tokenA.approve(address(migrator), 100 ether);

        vm.expectRevert(IPredictionMigrator.WinningEntryNotMigrated.selector);
        migrator.claim(address(oracle), 100 ether);
    }

    function test_claim_TransfersCorrectProRataAmount() public {
        uint256 claimableSupply = _setupWinningEntry();
        uint256 totalPot = 150 ether; // 100 + 50

        // Give alice some winning tokens (directly, simulating purchase)
        tokenA.transfer(alice, 100_000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(migrator), 100_000 ether);

        uint256 expectedClaim = (100_000 ether * totalPot) / claimableSupply;
        uint256 aliceNumeraireBefore = numeraire.balanceOf(alice);

        migrator.claim(address(oracle), 100_000 ether);

        assertEq(numeraire.balanceOf(alice) - aliceNumeraireBefore, expectedClaim);
        vm.stopPrank();
    }

    function test_claim_TransfersTokensToMigrator() public {
        _setupWinningEntry();

        tokenA.transfer(alice, 100_000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(migrator), 100_000 ether);

        uint256 migratorBalanceBefore = tokenA.balanceOf(address(migrator));

        migrator.claim(address(oracle), 100_000 ether);

        assertEq(tokenA.balanceOf(address(migrator)) - migratorBalanceBefore, 100_000 ether);
        assertEq(tokenA.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_claim_EmitsClaimed() public {
        uint256 claimableSupply = _setupWinningEntry();
        uint256 totalPot = 150 ether;
        uint256 claimAmount = 100_000 ether;
        uint256 expectedNumeraire = (claimAmount * totalPot) / claimableSupply;

        tokenA.transfer(alice, claimAmount);

        vm.startPrank(alice);
        tokenA.approve(address(migrator), claimAmount);

        vm.expectEmit(true, true, false, true);
        emit IPredictionMigrator.Claimed(address(oracle), alice, claimAmount, expectedNumeraire);

        migrator.claim(address(oracle), claimAmount);
        vm.stopPrank();
    }

    function test_claim_LazilyResolvesMarket() public {
        _setupWinningEntry();

        IPredictionMigrator.MarketView memory marketBefore = migrator.getMarket(address(oracle));
        assertFalse(marketBefore.isResolved);

        tokenA.transfer(alice, 100_000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(migrator), 100_000 ether);
        migrator.claim(address(oracle), 100_000 ether);
        vm.stopPrank();

        IPredictionMigrator.MarketView memory marketAfter = migrator.getMarket(address(oracle));
        assertTrue(marketAfter.isResolved);
        assertEq(marketAfter.winningToken, address(tokenA));
    }

    function test_claim_AllowsMultipleClaims() public {
        uint256 claimableSupply = _setupWinningEntry();
        uint256 totalPot = 150 ether;

        tokenA.transfer(alice, 200_000 ether);
        tokenA.transfer(bob, 100_000 ether);

        // Alice claims
        vm.startPrank(alice);
        tokenA.approve(address(migrator), 200_000 ether);
        migrator.claim(address(oracle), 200_000 ether);
        vm.stopPrank();

        // Bob claims
        vm.startPrank(bob);
        tokenA.approve(address(migrator), 100_000 ether);
        migrator.claim(address(oracle), 100_000 ether);
        vm.stopPrank();

        uint256 aliceExpected = (200_000 ether * totalPot) / claimableSupply;
        uint256 bobExpected = (100_000 ether * totalPot) / claimableSupply;

        assertEq(numeraire.balanceOf(alice), aliceExpected);
        assertEq(numeraire.balanceOf(bob), bobExpected);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                 previewClaim()                                   */
    /* -------------------------------------------------------------------------------- */

    function test_previewClaim_ReturnsCorrectAmount() public {
        uint256 claimableSupply = _setupWinningEntry();
        uint256 totalPot = 150 ether;
        uint256 tokenAmount = 100_000 ether;

        uint256 expected = (tokenAmount * totalPot) / claimableSupply;
        uint256 preview = migrator.previewClaim(address(oracle), tokenAmount);

        assertEq(preview, expected);
    }

    function test_previewClaim_ReturnsZeroWhenNoClaimableSupply() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        // Entry exists but not migrated, so claimableSupply is 0

        uint256 preview = migrator.previewClaim(address(oracle), 100_000 ether);
        assertEq(preview, 0);
    }

    /* -------------------------------------------------------------------------------- */
    /*                              getEntryByToken()                                   */
    /* -------------------------------------------------------------------------------- */

    function test_getEntryByToken_ReturnsCorrectEntry() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));

        IPredictionMigrator.EntryView memory entry = migrator.getEntryByToken(address(oracle), address(tokenA));
        assertEq(entry.token, address(tokenA));
        assertEq(entry.entryId, entryIdA);
    }

    /* -------------------------------------------------------------------------------- */
    /*                             ETH Numeraire Tests                                  */
    /* -------------------------------------------------------------------------------- */

    function test_migrate_WithETHNumeraire() public {
        // Use address(0) for ETH
        migrator.initialize(address(tokenA), address(0), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // Send ETH to migrator
        deal(address(this), 100 ether);
        payable(address(migrator)).transfer(100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);

        migrator.migrate(0, address(tokenA), address(0), address(0));

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(market.totalPot, 100 ether);
        assertEq(market.numeraire, address(0));
    }

    function test_claim_WithETHNumeraire() public {
        // Setup with ETH numeraire
        migrator.initialize(address(tokenA), address(0), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        deal(address(this), 100 ether);
        payable(address(migrator)).transfer(100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);

        migrator.migrate(0, address(tokenA), address(0), address(0));

        uint256 claimableSupply = 600_000 ether;
        uint256 claimAmount = 100_000 ether;
        uint256 expectedETH = (claimAmount * 100 ether) / claimableSupply;

        tokenA.transfer(alice, claimAmount);

        vm.startPrank(alice);
        tokenA.approve(address(migrator), claimAmount);

        uint256 aliceETHBefore = alice.balance;
        migrator.claim(address(oracle), claimAmount);
        uint256 aliceETHAfter = alice.balance;

        assertEq(aliceETHAfter - aliceETHBefore, expectedETH);
        vm.stopPrank();
    }
}

/* -------------------------------------------------------------------------------- */
/*                           MockPredictionOracle Tests                             */
/* -------------------------------------------------------------------------------- */

contract MockPredictionOracleTest is Test {
    MockPredictionOracle public oracle;

    function setUp() public {
        oracle = new MockPredictionOracle();
    }

    function test_constructor_SetsOwner() public view {
        assertEq(oracle.owner(), address(this));
    }

    function test_getWinner_ReturnsZeroBeforeFinalized() public view {
        (address winner, bool isFinalized) = oracle.getWinner(address(oracle));
        assertEq(winner, address(0));
        assertFalse(isFinalized);
    }

    function test_setWinner_SetsWinnerAndFinalizes() public {
        address winningToken = address(0x1234);
        oracle.setWinner(winningToken);

        (address winner, bool isFinalized) = oracle.getWinner(address(oracle));
        assertEq(winner, winningToken);
        assertTrue(isFinalized);
    }

    function test_setWinner_EmitsWinnerDeclared() public {
        address winningToken = address(0x1234);

        vm.expectEmit(true, true, false, false);
        emit IPredictionOracle.WinnerDeclared(address(oracle), winningToken);

        oracle.setWinner(winningToken);
    }

    function test_setWinner_RevertsWhenNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(OnlyOwner.selector);
        oracle.setWinner(address(0x1234));
    }

    function test_setWinner_RevertsWhenAlreadyFinalized() public {
        oracle.setWinner(address(0x1234));

        vm.expectRevert(AlreadyFinalized.selector);
        oracle.setWinner(address(0x5678));
    }
}
