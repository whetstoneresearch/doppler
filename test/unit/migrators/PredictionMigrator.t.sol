// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { AlreadyFinalized, MockPredictionOracle, OnlyOwner } from "src/base/MockPredictionOracle.sol";
import { IPredictionMigrator } from "src/interfaces/IPredictionMigrator.sol";
import { IPredictionOracle } from "src/interfaces/IPredictionOracle.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";

/// @dev Simple ERC20 mock for testing with totalSupply support and burn()
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns tokens from the caller's balance (matches DERC20/CloneERC20 interface)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev ERC20 mock intentionally missing burn() to test strict burn requirement.
contract MockERC20NoBurn is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PredictionMigratorTest is Test {
    PredictionMigrator public migrator;
    MockPredictionOracle public oracle;
    MockPredictionOracle public oracle2;

    address public airlock;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockERC20 public numeraire;

    bytes32 public entryIdA;
    bytes32 public entryIdB;
    bytes32 public entryIdC;

    function setUp() public {
        airlock = address(this); // Test contract acts as Airlock
        migrator = new PredictionMigrator(airlock);
        oracle = new MockPredictionOracle();
        oracle2 = new MockPredictionOracle();

        tokenA = new MockERC20("Token A", "TKNA", 1_000_000 ether);
        tokenB = new MockERC20("Token B", "TKNB", 1_000_000 ether);
        tokenC = new MockERC20("Token C", "TKNC", 1_000_000 ether);
        numeraire = new MockERC20("Numeraire", "NUM", 1_000_000 ether);

        entryIdA = keccak256(abi.encodePacked("entry_a"));
        entryIdB = keccak256(abi.encodePacked("entry_b"));
        entryIdC = keccak256(abi.encodePacked("entry_c"));
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

    function test_initialize_AllowsMultipleEntriesWithETHNumeraire() public {
        migrator.initialize(address(tokenA), address(0), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(0), abi.encode(address(oracle), entryIdB));

        IPredictionMigrator.EntryView memory entryA = migrator.getEntry(address(oracle), entryIdA);
        IPredictionMigrator.EntryView memory entryB = migrator.getEntry(address(oracle), entryIdB);
        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));

        assertEq(entryA.token, address(tokenA));
        assertEq(entryB.token, address(tokenB));
        assertEq(market.numeraire, address(0));
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

    function test_initialize_RevertsOnNumeraireMismatch_WhenMarketNumeraireIsETH() public {
        migrator.initialize(address(tokenA), address(0), abi.encode(address(oracle), entryIdA));

        vm.expectRevert(IPredictionMigrator.NumeraireMismatch.selector);
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));
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

    function test_migrate_BurnsUnsoldTokens() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), unsoldTokens);

        uint256 totalSupplyBefore = tokenA.totalSupply();

        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Unsold tokens should be burned (supply decreased)
        assertEq(tokenA.totalSupply(), totalSupplyBefore - unsoldTokens);
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

    function test_migrate_RevertsWhenBothPairTokensAreRegisteredEntries() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));
        oracle.setWinner(address(tokenA));

        vm.expectRevert(IPredictionMigrator.InvalidTokenPair.selector);
        migrator.migrate(0, address(tokenA), address(tokenB), address(0));
    }

    function test_migrate_RevertsOnPairNumeraireMismatch() public {
        MockERC20 otherNumeraire = new MockERC20("Other Numeraire", "ONUM", 1_000_000 ether);

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        vm.expectRevert(IPredictionMigrator.NumeraireMismatch.selector);
        migrator.migrate(0, address(tokenA), address(otherNumeraire), address(0));
    }

    function test_migrate_HandlesTokenOrdering_WhenAssetIsToken1() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        uint256 numeraireAmount = 100 ether;
        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), numeraireAmount);
        tokenA.transfer(address(migrator), unsoldTokens);

        // Asset is token1 in this ordering.
        migrator.migrate(0, address(numeraire), address(tokenA), address(0));

        IPredictionMigrator.EntryView memory entry = migrator.getEntry(address(oracle), entryIdA);
        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(entry.contribution, numeraireAmount);
        assertEq(entry.claimableSupply, 1_000_000 ether - unsoldTokens);
        assertEq(market.totalPot, numeraireAmount);
    }

    function test_migrate_RevertsWhenBurnUnavailable() public {
        MockERC20NoBurn tokenNoBurn = new MockERC20NoBurn("Token No Burn", "NOBURN", 1_000_000 ether);
        bytes32 entryIdNoBurn = keccak256(abi.encodePacked("entry_no_burn"));

        migrator.initialize(address(tokenNoBurn), address(numeraire), abi.encode(address(oracle), entryIdNoBurn));
        oracle.setWinner(address(tokenNoBurn));

        uint256 unsoldTokens = 400_000 ether;
        numeraire.transfer(address(migrator), 100 ether);
        tokenNoBurn.transfer(address(migrator), unsoldTokens);

        vm.expectRevert();
        migrator.migrate(0, address(tokenNoBurn), address(numeraire), address(0));
    }

    function test_migrate_MultiMarketSharedNumeraire_AttributesOnlyPerMigrationDelta() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenC), address(numeraire), abi.encode(address(oracle2), entryIdC));
        oracle.setWinner(address(tokenA));
        oracle2.setWinner(address(tokenC));

        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        numeraire.transfer(address(migrator), 50 ether);
        tokenC.transfer(address(migrator), 500_000 ether);
        migrator.migrate(0, address(tokenC), address(numeraire), address(0));

        IPredictionMigrator.EntryView memory entryA = migrator.getEntry(address(oracle), entryIdA);
        IPredictionMigrator.EntryView memory entryC = migrator.getEntry(address(oracle2), entryIdC);
        IPredictionMigrator.MarketView memory marketA = migrator.getMarket(address(oracle));
        IPredictionMigrator.MarketView memory marketC = migrator.getMarket(address(oracle2));

        assertEq(entryA.contribution, 100 ether);
        assertEq(entryC.contribution, 50 ether);
        assertEq(marketA.totalPot, 100 ether);
        assertEq(marketC.totalPot, 50 ether);
    }

    function test_migrate_MultiMarketSharedNumeraire_ClaimInMarketADoesNotContaminateMarketB() public {
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenC), address(numeraire), abi.encode(address(oracle2), entryIdC));
        oracle.setWinner(address(tokenA));
        oracle2.setWinner(address(tokenC));

        // Migrate market A entry
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Claim from market A before market B migration
        tokenA.transfer(alice, 300_000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(migrator), 300_000 ether);
        migrator.claim(address(oracle), 300_000 ether); // 50 ether payout
        vm.stopPrank();
        assertEq(numeraire.balanceOf(alice), 50 ether);

        // Migrate market B entry and verify only this migration's transfer is attributed.
        numeraire.transfer(address(migrator), 40 ether);
        tokenC.transfer(address(migrator), 500_000 ether);
        migrator.migrate(0, address(tokenC), address(numeraire), address(0));

        IPredictionMigrator.EntryView memory entryC = migrator.getEntry(address(oracle2), entryIdC);
        IPredictionMigrator.MarketView memory marketC = migrator.getMarket(address(oracle2));
        assertEq(entryC.contribution, 40 ether);
        assertEq(marketC.totalPot, 40 ether);
    }

    function testFuzz_migrate_MultiMarketSharedNumeraire_ClaimGapIsolation(
        uint128 amountASeed,
        uint128 amountBSeed,
        uint128 claimTokenSeed
    ) public {
        uint256 amountA = bound(uint256(amountASeed), 1, 250_000 ether);
        uint256 amountB = bound(uint256(amountBSeed), 1, 250_000 ether);
        uint256 claimTokens = bound(uint256(claimTokenSeed), 1, 300_000 ether);

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenC), address(numeraire), abi.encode(address(oracle2), entryIdC));
        oracle.setWinner(address(tokenA));
        oracle2.setWinner(address(tokenC));

        // Market A migrates first.
        numeraire.transfer(address(migrator), amountA);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Claim from market A before market B migration.
        tokenA.transfer(alice, claimTokens);
        vm.startPrank(alice);
        tokenA.approve(address(migrator), claimTokens);
        migrator.claim(address(oracle), claimTokens);
        vm.stopPrank();

        // Market B migration contribution must equal only its own transfer.
        numeraire.transfer(address(migrator), amountB);
        tokenC.transfer(address(migrator), 500_000 ether);
        migrator.migrate(0, address(tokenC), address(numeraire), address(0));

        IPredictionMigrator.EntryView memory entryB = migrator.getEntry(address(oracle2), entryIdC);
        IPredictionMigrator.MarketView memory marketB = migrator.getMarket(address(oracle2));
        assertEq(entryB.contribution, amountB);
        assertEq(marketB.totalPot, amountB);
    }

    function testFuzz_claim_PreviewMatchesPayout_AndClaimedNeverExceedsPot(
        uint128 migratedAmountSeed,
        uint128 aliceClaimSeed,
        uint128 bobClaimSeed
    ) public {
        uint256 migratedAmount = bound(uint256(migratedAmountSeed), 1, 500_000 ether);

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        // Fixed unsold amount => fixed claimable supply of 600k.
        numeraire.transfer(address(migrator), migratedAmount);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        uint256 aliceClaimTokens = bound(uint256(aliceClaimSeed), 0, 600_000 ether);
        uint256 bobClaimTokens = bound(uint256(bobClaimSeed), 0, 600_000 ether - aliceClaimTokens);

        uint256 expectedAlice = migrator.previewClaim(address(oracle), aliceClaimTokens);
        uint256 expectedBob = migrator.previewClaim(address(oracle), bobClaimTokens);

        if (aliceClaimTokens > 0) {
            tokenA.transfer(alice, aliceClaimTokens);
            vm.startPrank(alice);
            tokenA.approve(address(migrator), aliceClaimTokens);
            migrator.claim(address(oracle), aliceClaimTokens);
            vm.stopPrank();
        }

        if (bobClaimTokens > 0) {
            tokenA.transfer(bob, bobClaimTokens);
            vm.startPrank(bob);
            tokenA.approve(address(migrator), bobClaimTokens);
            migrator.claim(address(oracle), bobClaimTokens);
            vm.stopPrank();
        }

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(numeraire.balanceOf(alice), expectedAlice);
        assertEq(numeraire.balanceOf(bob), expectedBob);
        assertEq(market.totalClaimed, expectedAlice + expectedBob);
        assertLe(market.totalClaimed, market.totalPot);
    }

    function testFuzz_migrate_TokenOrderingAssetAsToken1_ContributionMatchesTransfer(uint128 amountSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 500_000 ether);

        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        oracle.setWinner(address(tokenA));

        numeraire.transfer(address(migrator), amount);
        tokenA.transfer(address(migrator), 400_000 ether);

        // Asset is token1 in this ordering.
        migrator.migrate(0, address(numeraire), address(tokenA), address(0));

        IPredictionMigrator.EntryView memory entry = migrator.getEntry(address(oracle), entryIdA);
        assertEq(entry.contribution, amount);
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

    /* -------------------------------------------------------------------------------- */
    /*                     BUG TESTS: Claim Before All Migrate                         */
    /* -------------------------------------------------------------------------------- */

    /**
     * @notice This test verifies the fix for claiming before all entries migrate.
     * Global per-numeraire accounting ensures correct numeraire amount calculation.
     *
     * Scenario:
     * 1. Entry A (winner) and Entry B (loser) both register
     * 2. Oracle finalizes, Entry A wins
     * 3. Entry A migrates with 100 ETH -> totalPot = 100
     * 4. User claims 50 ETH -> balance = 50, totalClaimed = 50
     * 5. Entry B migrates with 40 ETH -> balance = 90
     *    numeraireAmount = 90 - 50(accounted after claim) = 40 ✓
     */
    function test_migrate_ClaimBeforeAllMigrate_Works() public {
        // Setup: Register both entries
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));

        // Oracle finalizes - Entry A wins
        oracle.setWinner(address(tokenA));

        // Entry A migrates with 100 numeraire
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether); // unsold tokens
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Verify Entry A migrated correctly
        IPredictionMigrator.MarketView memory marketAfterA = migrator.getMarket(address(oracle));
        assertEq(marketAfterA.totalPot, 100 ether);
        assertEq(marketAfterA.totalClaimed, 0);

        // User claims 50% of their tokens (gets 50 ETH out)
        tokenA.transfer(alice, 300_000 ether); // Give alice half the claimable supply (600k)

        vm.startPrank(alice);
        tokenA.approve(address(migrator), 300_000 ether);
        migrator.claim(address(oracle), 300_000 ether); // Claims 50 ETH
        vm.stopPrank();

        // Verify claim worked - alice should have 50 ETH
        assertEq(numeraire.balanceOf(alice), 50 ether);

        // Verify totalClaimed was incremented
        IPredictionMigrator.MarketView memory marketAfterClaim = migrator.getMarket(address(oracle));
        assertEq(marketAfterClaim.totalPot, 100 ether);
        assertEq(marketAfterClaim.totalClaimed, 50 ether);

        // Entry B migrates with 40 numeraire - should work now!
        numeraire.transfer(address(migrator), 40 ether);
        tokenB.transfer(address(migrator), 600_000 ether); // unsold tokens
        migrator.migrate(0, address(tokenB), address(numeraire), address(0));

        // Verify Entry B migrated correctly
        IPredictionMigrator.MarketView memory marketFinal = migrator.getMarket(address(oracle));
        assertEq(marketFinal.totalPot, 140 ether); // 100 + 40
        assertEq(marketFinal.totalClaimed, 50 ether);

        // Verify entry B contribution
        IPredictionMigrator.EntryView memory entryB = migrator.getEntry(address(oracle), entryIdB);
        assertEq(entryB.contribution, 40 ether);
        assertTrue(entryB.isMigrated);
    }

    /**
     * @notice Test that demonstrates the correct behavior when all entries
     * migrate BEFORE any claims happen.
     */
    function test_migrate_AllEntriesMigrateBeforeClaims_Works() public {
        // Setup: Register both entries
        migrator.initialize(address(tokenA), address(numeraire), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(numeraire), abi.encode(address(oracle), entryIdB));

        // Oracle finalizes - Entry A wins
        oracle.setWinner(address(tokenA));

        // Entry A migrates
        numeraire.transfer(address(migrator), 100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(numeraire), address(0));

        // Entry B migrates BEFORE any claims
        numeraire.transfer(address(migrator), 50 ether);
        tokenB.transfer(address(migrator), 600_000 ether);
        migrator.migrate(0, address(tokenB), address(numeraire), address(0));

        // Verify total pot
        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        assertEq(market.totalPot, 150 ether); // 100 + 50

        // Now claims should work correctly
        tokenA.transfer(alice, 300_000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(migrator), 300_000 ether);
        migrator.claim(address(oracle), 300_000 ether);
        vm.stopPrank();

        // Alice should get (300k / 600k) * 150 = 75 ETH
        assertEq(numeraire.balanceOf(alice), 75 ether);
    }

    /**
     * @notice Test with ETH numeraire verifies the fix works for native ETH too
     */
    function test_migrate_ClaimBeforeAllMigrate_ETH_Works() public {
        // Setup with ETH as numeraire
        migrator.initialize(address(tokenA), address(0), abi.encode(address(oracle), entryIdA));
        migrator.initialize(address(tokenB), address(0), abi.encode(address(oracle), entryIdB));

        oracle.setWinner(address(tokenA));

        // Entry A migrates with 100 ETH
        deal(address(this), 200 ether);
        payable(address(migrator)).transfer(100 ether);
        tokenA.transfer(address(migrator), 400_000 ether);
        migrator.migrate(0, address(tokenA), address(0), address(0));

        // Verify Entry A state
        IPredictionMigrator.MarketView memory marketAfterA = migrator.getMarket(address(oracle));
        assertEq(marketAfterA.totalPot, 100 ether);
        assertEq(marketAfterA.totalClaimed, 0);

        // User claims
        tokenA.transfer(alice, 300_000 ether);

        uint256 aliceBalanceBefore = alice.balance;
        vm.startPrank(alice);
        tokenA.approve(address(migrator), 300_000 ether);
        migrator.claim(address(oracle), 300_000 ether); // Claims 50 ETH
        vm.stopPrank();

        assertEq(alice.balance - aliceBalanceBefore, 50 ether);

        // Verify totalClaimed
        IPredictionMigrator.MarketView memory marketAfterClaim = migrator.getMarket(address(oracle));
        assertEq(marketAfterClaim.totalClaimed, 50 ether);

        // Entry B migrates - should work now!
        payable(address(migrator)).transfer(40 ether);
        tokenB.transfer(address(migrator), 600_000 ether);
        migrator.migrate(0, address(tokenB), address(0), address(0));

        // Verify final state
        IPredictionMigrator.MarketView memory marketFinal = migrator.getMarket(address(oracle));
        assertEq(marketFinal.totalPot, 140 ether);
        assertEq(marketFinal.totalClaimed, 50 ether);

        IPredictionMigrator.EntryView memory entryB = migrator.getEntry(address(oracle), entryIdB);
        assertEq(entryB.contribution, 40 ether);
        assertTrue(entryB.isMigrated);
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
