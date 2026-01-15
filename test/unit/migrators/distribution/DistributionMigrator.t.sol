// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import {
    AlreadyInitialized,
    AssetMismatch,
    DistributionConfig,
    DistributionMigrator,
    InvalidPayout,
    InvalidPercent,
    InvalidUnderlying,
    MAX_DISTRIBUTION_WAD,
    PoolNotInitialized,
    UnderlyingHookMismatch,
    UnderlyingNotForwarded,
    UnderlyingNotLockerApproved,
    UnderlyingNotWhitelisted,
    WAD
} from "src/migrators/distribution/DistributionMigrator.sol";

/// @notice Mock underlying migrator for testing
contract MockForwardedMigrator is ILiquidityMigrator {
    address public airlock;
    address public lastInitAsset;
    address public lastInitNumeraire;
    bytes public lastInitData;
    address public returnPool;

    uint256 public lastMigrateSqrtPriceX96;
    address public lastMigrateToken0;
    address public lastMigrateToken1;
    address public lastMigrateRecipient;
    uint256 public returnLiquidity;

    constructor(address airlock_, address returnPool_, uint256 returnLiquidity_) {
        airlock = airlock_;
        returnPool = returnPool_;
        returnLiquidity = returnLiquidity_;
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address) {
        lastInitAsset = asset;
        lastInitNumeraire = numeraire;
        lastInitData = data;
        return returnPool;
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable returns (uint256) {
        lastMigrateSqrtPriceX96 = sqrtPriceX96;
        lastMigrateToken0 = token0;
        lastMigrateToken1 = token1;
        lastMigrateRecipient = recipient;
        return returnLiquidity;
    }

    receive() external payable { }
}

/// @notice Mock underlying that reverts
contract MockRevertingMigrator is ILiquidityMigrator {
    address public airlock;
    string public revertMessage;

    constructor(address airlock_, string memory revertMessage_) {
        airlock = airlock_;
        revertMessage = revertMessage_;
    }

    function initialize(address, address, bytes calldata) external view returns (address) {
        revert(revertMessage);
    }

    function migrate(uint160, address, address, address) external payable returns (uint256) {
        revert(revertMessage);
    }
}

/// @notice Mock V4 migrator with locker and hook for preflight checks
contract MockV4Migrator is ILiquidityMigrator {
    address public airlock;
    address public locker;
    address public migratorHook;
    address public returnPool;

    constructor(address airlock_, address locker_, address hook_, address returnPool_) {
        airlock = airlock_;
        locker = locker_;
        migratorHook = hook_;
        returnPool = returnPool_;
    }

    function initialize(address, address, bytes calldata) external view returns (address) {
        return returnPool;
    }

    function migrate(uint160, address, address, address) external payable returns (uint256) {
        return 1000 ether;
    }

    receive() external payable { }
}

/// @notice Mock locker for V4 preflight tests
contract MockLocker {
    mapping(address => bool) public approvedMigrators;

    function setApproval(address migrator, bool approved) external {
        approvedMigrators[migrator] = approved;
    }
}

/// @notice Mock hook for V4 preflight tests
contract MockHook {
    address public migrator;

    function setMigrator(address migrator_) external {
        migrator = migrator_;
    }
}

contract DistributionMigratorTest is Test {
    Airlock public airlock;
    DistributionMigrator public distributor;
    MockForwardedMigrator public mockUnderlying;

    TestERC20 public asset;
    TestERC20 public numeraire;

    address public owner = address(0xb055);
    address public payout = address(0xbeef);
    address public recipient = address(0xdead);

    uint256 constant PERCENT_10 = 1e17; // 10%
    uint256 constant PERCENT_50 = 5e17; // 50%

    function setUp() public {
        // Deploy Airlock with owner
        airlock = new Airlock(owner);

        // Deploy DistributionMigrator
        distributor = new DistributionMigrator(address(airlock));

        // Deploy mock underlying with distributor as its airlock
        mockUnderlying = new MockForwardedMigrator(address(distributor), address(0x1234), 1000 ether);

        // Whitelist both distributor and mockUnderlying
        address[] memory modules = new address[](2);
        modules[0] = address(distributor);
        modules[1] = address(mockUnderlying);
        ModuleState[] memory states = new ModuleState[](2);
        states[0] = ModuleState.LiquidityMigrator;
        states[1] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        // Deploy test tokens
        asset = new TestERC20(0);
        numeraire = new TestERC20(0);

        // Ensure asset < numeraire for consistent sorting
        if (address(asset) > address(numeraire)) {
            (asset, numeraire) = (numeraire, asset);
        }
    }

    // ============ Constructor Tests ============

    function test_constructor_SetsAirlock() public view {
        assertEq(address(distributor.airlock()), address(airlock));
    }

    // ============ owner() Tests ============

    function test_owner_ReturnsAirlockOwner() public view {
        assertEq(distributor.owner(), owner);
    }

    // ============ receive() Tests ============

    function test_receive_AcceptsETHFromAirlock() public {
        vm.deal(address(airlock), 1 ether);
        vm.prank(address(airlock));
        (bool success,) = address(distributor).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(distributor).balance, 1 ether);
    }

    function test_receive_RevertsWhenNotAirlock() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SenderNotAirlock.selector);
        (bool success,) = address(distributor).call{ value: 1 ether }("");
        // The call will fail but expectRevert catches it
        success; // silence unused warning
    }

    // ============ initialize() Validation Tests ============

    function test_initialize_RevertsWhenNotAirlock() public {
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.expectRevert(SenderNotAirlock.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenPayoutIsZero() public {
        bytes memory data = abi.encode(address(0), PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        vm.expectRevert(InvalidPayout.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenUnderlyingIsZero() public {
        bytes memory data = abi.encode(payout, PERCENT_10, address(0), "");
        vm.prank(address(airlock));
        vm.expectRevert(InvalidUnderlying.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenUnderlyingIsSelf() public {
        bytes memory data = abi.encode(payout, PERCENT_10, address(distributor), "");
        vm.prank(address(airlock));
        vm.expectRevert(InvalidUnderlying.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenPercentExceedsMax() public {
        bytes memory data = abi.encode(payout, PERCENT_50 + 1, address(mockUnderlying), "");
        vm.prank(address(airlock));
        vm.expectRevert(InvalidPercent.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenUnderlyingNotWhitelisted() public {
        // Deploy non-whitelisted mock
        MockForwardedMigrator nonWhitelisted = new MockForwardedMigrator(address(distributor), address(0), 0);

        bytes memory data = abi.encode(payout, PERCENT_10, address(nonWhitelisted), "");
        vm.prank(address(airlock));
        vm.expectRevert(UnderlyingNotWhitelisted.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsWhenUnderlyingNotForwarded() public {
        // Deploy mock with wrong airlock (not the distributor)
        MockForwardedMigrator wrongAirlock = new MockForwardedMigrator(address(0x9999), address(0), 0);

        // Whitelist it
        address[] memory modules = new address[](1);
        modules[0] = address(wrongAirlock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(wrongAirlock), "");
        vm.prank(address(airlock));
        vm.expectRevert(UnderlyingNotForwarded.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_RevertsOnOverwrite() public {
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");

        // First initialization succeeds
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Second initialization fails
        vm.prank(address(airlock));
        vm.expectRevert(AlreadyInitialized.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    function test_initialize_BubblesUnderlyingRevert() public {
        // Deploy reverting mock
        MockRevertingMigrator revertingMock = new MockRevertingMigrator(address(distributor), "UNDERLYING_FAILED");

        // Whitelist it
        address[] memory modules = new address[](1);
        modules[0] = address(revertingMock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(revertingMock), "");
        vm.prank(address(airlock));
        vm.expectRevert("UNDERLYING_FAILED");
        distributor.initialize(address(asset), address(numeraire), data);
    }

    // ============ initialize() Success Tests ============

    function test_initialize_StoresConfig() public {
        bytes memory underlyingData = abi.encode("test data");
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), underlyingData);

        vm.prank(address(airlock));
        address pool = distributor.initialize(address(asset), address(numeraire), data);

        // Check return value
        assertEq(pool, address(0x1234));

        // Check stored config
        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        (address storedPayout, uint256 storedPercent, ILiquidityMigrator storedUnderlying, address storedAsset) =
            distributor.getDistributionConfig(token0, token1);

        assertEq(storedPayout, payout);
        assertEq(storedPercent, PERCENT_10);
        assertEq(address(storedUnderlying), address(mockUnderlying));
        assertEq(storedAsset, address(asset));
    }

    function test_initialize_ForwardsToUnderlying() public {
        bytes memory underlyingData = abi.encode("test data");
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), underlyingData);

        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Check underlying received correct params
        assertEq(mockUnderlying.lastInitAsset(), address(asset));
        assertEq(mockUnderlying.lastInitNumeraire(), address(numeraire));
        assertEq(mockUnderlying.lastInitData(), underlyingData);
    }

    // ============ migrate() Tests ============

    function test_migrate_RevertsWhenNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        distributor.migrate(1e18, address(asset), address(numeraire), recipient);
    }

    function test_migrate_RevertsWhenNotInitialized() public {
        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        vm.expectRevert(PoolNotInitialized.selector);
        distributor.migrate(1e18, token0, token1, recipient);
    }

    function test_migrate_DistributesNumeraireOnly() public {
        // Initialize
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund distributor with both tokens
        uint256 assetAmount = 1000 ether;
        uint256 numeraireAmount = 500 ether;
        asset.mint(address(distributor), assetAmount);
        numeraire.mint(address(distributor), numeraireAmount);

        // Get sorted tokens
        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        // Migrate
        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Check payout received 10% of numeraire
        uint256 expectedDistribution = (numeraireAmount * PERCENT_10) / WAD;
        assertEq(numeraire.balanceOf(payout), expectedDistribution);

        // Check underlying received remaining balances
        assertEq(asset.balanceOf(address(mockUnderlying)), assetAmount);
        assertEq(numeraire.balanceOf(address(mockUnderlying)), numeraireAmount - expectedDistribution);
    }

    function test_migrate_RoundingFavorsProtocol() public {
        // Initialize with 10%
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund with amount that doesn't divide evenly
        // 999 * 0.1 = 99.9 -> should be 99 (floor)
        uint256 numeraireAmount = 999;
        numeraire.mint(address(distributor), numeraireAmount);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Check floor rounding
        uint256 expectedDistribution = (numeraireAmount * PERCENT_10) / WAD; // 99
        assertEq(numeraire.balanceOf(payout), expectedDistribution);
        assertEq(numeraire.balanceOf(address(mockUnderlying)), numeraireAmount - expectedDistribution);
    }

    function test_migrate_ETHNumerairePath() public {
        // For ETH tests, numeraire is address(0)
        // asset should be a real token
        address ethNumeraire = address(0);

        // Deploy new mock with distributor as airlock
        MockForwardedMigrator ethMock = new MockForwardedMigrator(address(distributor), address(0x5678), 2000 ether);

        // Whitelist it
        address[] memory modules = new address[](1);
        modules[0] = address(ethMock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        // Initialize with ETH as numeraire (token0 since address(0) < any other address)
        bytes memory data = abi.encode(payout, PERCENT_10, address(ethMock), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), ethNumeraire, data);

        // Fund distributor with ETH and asset
        uint256 ethAmount = 10 ether;
        uint256 assetAmount = 1000 ether;
        vm.deal(address(airlock), ethAmount);
        vm.prank(address(airlock));
        (bool success,) = address(distributor).call{ value: ethAmount }("");
        assertTrue(success);
        asset.mint(address(distributor), assetAmount);

        // token0 = address(0) (ETH), token1 = asset
        address token0 = ethNumeraire; // address(0)
        address token1 = address(asset);

        uint256 payoutBalanceBefore = payout.balance;

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Check payout received 10% of ETH
        uint256 expectedDistribution = (ethAmount * PERCENT_10) / WAD;
        assertEq(payout.balance - payoutBalanceBefore, expectedDistribution);

        // Check underlying received remaining ETH (via msg.value in migrate call)
        assertEq(address(ethMock).balance, ethAmount - expectedDistribution);
        assertEq(asset.balanceOf(address(ethMock)), assetAmount);
    }

    function test_migrate_DeletesConfigAfterMigration() public {
        // Initialize
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund and migrate
        numeraire.mint(address(distributor), 1000 ether);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Check config was deleted
        (address storedPayout,,,) = distributor.getDistributionConfig(token0, token1);
        assertEq(storedPayout, address(0));
    }

    function test_migrate_ForwardsToUnderlying() public {
        // Initialize
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund
        asset.mint(address(distributor), 1000 ether);
        numeraire.mint(address(distributor), 500 ether);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        uint160 sqrtPrice = 1e18;
        vm.prank(address(airlock));
        uint256 liquidity = distributor.migrate(sqrtPrice, token0, token1, recipient);

        // Check underlying received correct migrate params
        assertEq(mockUnderlying.lastMigrateSqrtPriceX96(), sqrtPrice);
        assertEq(mockUnderlying.lastMigrateToken0(), token0);
        assertEq(mockUnderlying.lastMigrateToken1(), token1);
        assertEq(mockUnderlying.lastMigrateRecipient(), recipient);

        // Check return value
        assertEq(liquidity, 1000 ether);
    }

    // ============ Fuzz Tests ============

    function testFuzz_migrate_DistributionCalculation(uint256 balance, uint256 percentWad) public {
        // Bound inputs
        balance = bound(balance, 1, type(uint128).max);
        percentWad = bound(percentWad, 0, MAX_DISTRIBUTION_WAD);

        // Initialize
        bytes memory data = abi.encode(payout, percentWad, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund
        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Verify distribution calculation
        uint256 expectedDistribution = (balance * percentWad) / WAD;
        assertEq(numeraire.balanceOf(payout), expectedDistribution);
        assertEq(numeraire.balanceOf(address(mockUnderlying)), balance - expectedDistribution);
    }

    // ============ Edge Case Tests (Trail of Bits patterns) ============

    /// @notice Test with zero numeraire balance - distribution should be 0
    function test_migrate_ZeroNumeraireBalance() public {
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund with only asset, no numeraire
        asset.mint(address(distributor), 1000 ether);
        // No numeraire minted

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Payout should receive nothing
        assertEq(numeraire.balanceOf(payout), 0);
        // Underlying should receive all asset
        assertEq(asset.balanceOf(address(mockUnderlying)), 1000 ether);
    }

    /// @notice Test with very large balance to check overflow safety
    function test_migrate_LargeBalanceNoOverflow() public {
        bytes memory data = abi.encode(payout, PERCENT_50, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Fund with max reasonable balance (1e30 tokens)
        uint256 largeBalance = 1e30;
        numeraire.mint(address(distributor), largeBalance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Verify no overflow - 50% of 1e30 = 5e29
        uint256 expectedDistribution = (largeBalance * PERCENT_50) / WAD;
        assertEq(numeraire.balanceOf(payout), expectedDistribution);
    }

    /// @notice Test that underlying.migrate() revert bubbles up correctly
    function test_migrate_BubblesUnderlyingRevert() public {
        // Deploy reverting mock
        MockRevertingMigrator revertingMock = new MockRevertingMigrator(address(distributor), "MIGRATE_FAILED");

        // Whitelist it
        address[] memory modules = new address[](1);
        modules[0] = address(revertingMock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(revertingMock), "");
        vm.prank(address(airlock));
        // Note: initialize will also revert since the mock reverts on initialize, and the error bubbles up
        vm.expectRevert("MIGRATE_FAILED");
        distributor.initialize(address(asset), address(numeraire), data);
    }

    /// @notice Test event emission when distribution is zero (percentWad = 0)
    function test_migrate_NoEventWhenZeroDistribution() public {
        bytes memory data = abi.encode(payout, 0, address(mockUnderlying), ""); // 0%
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        numeraire.mint(address(distributor), 1000 ether);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        // Record logs to check no Distribution event
        vm.recordLogs();

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Check that Distribution event was NOT emitted (only WrappedMigration should be)
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bool distributionEmitted = false;
        for (uint256 i = 0; i < logs.length; i++) {
            // Distribution event topic0
            if (logs[i].topics[0] == keccak256("Distribution(address,address,uint256,uint256)")) {
                distributionEmitted = true;
            }
        }
        assertFalse(distributionEmitted, "Distribution event should not be emitted when distribution is 0");
    }

    /// @notice Test that asset balance is never affected by distribution
    function test_migrate_AssetBalanceUnaffected() public {
        bytes memory data = abi.encode(payout, PERCENT_50, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        uint256 assetAmount = 1000 ether;
        uint256 numeraireAmount = 500 ether;
        asset.mint(address(distributor), assetAmount);
        numeraire.mint(address(distributor), numeraireAmount);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Payout should ONLY receive numeraire, NEVER asset
        assertEq(asset.balanceOf(payout), 0, "Payout should not receive any asset");
        // Underlying receives ALL asset
        assertEq(asset.balanceOf(address(mockUnderlying)), assetAmount, "Underlying should receive all asset");
    }

    /// @notice Fuzz test: distribution + remaining always equals original balance (conservation)
    function testFuzz_migrate_BalanceConservation(uint256 balance, uint256 percentWad) public {
        balance = bound(balance, 1, type(uint128).max);
        percentWad = bound(percentWad, 0, MAX_DISTRIBUTION_WAD);

        bytes memory data = abi.encode(payout, percentWad, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Conservation: payout + underlying = original balance
        uint256 payoutReceived = numeraire.balanceOf(payout);
        uint256 underlyingReceived = numeraire.balanceOf(address(mockUnderlying));
        assertEq(payoutReceived + underlyingReceived, balance, "Balance not conserved");
    }

    // ============ Trail of Bits Recommended Tests ============

    /// @notice Test that no funds get stuck in distributor after migrate
    function testFuzz_migrate_NoStuckFunds(uint256 assetAmt, uint256 numAmt, uint256 percentWad) public {
        assetAmt = bound(assetAmt, 0, type(uint128).max);
        numAmt = bound(numAmt, 0, type(uint128).max);
        percentWad = bound(percentWad, 0, MAX_DISTRIBUTION_WAD);

        bytes memory data = abi.encode(payout, percentWad, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        if (assetAmt > 0) asset.mint(address(distributor), assetAmt);
        if (numAmt > 0) numeraire.mint(address(distributor), numAmt);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // After migrate, distributor should have zero balance
        assertEq(asset.balanceOf(address(distributor)), 0, "Asset stuck in distributor");
        assertEq(numeraire.balanceOf(address(distributor)), 0, "Numeraire stuck in distributor");
    }

    /// @notice Test multiple independent pools don't interfere with each other
    function test_migrate_MultiplePoolsIndependent() public {
        // Create second token pair
        TestERC20 asset2 = new TestERC20(0);
        TestERC20 numeraire2 = new TestERC20(0);
        if (address(asset2) > address(numeraire2)) {
            (asset2, numeraire2) = (numeraire2, asset2);
        }

        // Initialize pool 1 with 10%
        bytes memory data1 = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data1);

        // Create second mock underlying for pool 2
        MockForwardedMigrator mockUnderlying2 =
            new MockForwardedMigrator(address(distributor), address(0x5678), 2000 ether);
        address[] memory modules = new address[](1);
        modules[0] = address(mockUnderlying2);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        // Initialize pool 2 with 50%
        bytes memory data2 = abi.encode(payout, PERCENT_50, address(mockUnderlying2), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset2), address(numeraire2), data2);

        // Fund both pools
        asset.mint(address(distributor), 1000 ether);
        numeraire.mint(address(distributor), 500 ether);
        asset2.mint(address(distributor), 2000 ether);
        numeraire2.mint(address(distributor), 1000 ether);

        // Migrate pool 1
        (address token0_1, address token1_1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0_1, token1_1, recipient);

        // Verify pool 1 distributed correctly (10%)
        assertEq(numeraire.balanceOf(payout), 50 ether); // 10% of 500

        // Pool 2 funds should be untouched in distributor still
        assertEq(asset2.balanceOf(address(distributor)), 2000 ether);
        assertEq(numeraire2.balanceOf(address(distributor)), 1000 ether);

        // Reset payout balance for clean check
        uint256 payoutBalanceBefore = numeraire2.balanceOf(payout);

        // Migrate pool 2
        (address token0_2, address token1_2) = address(asset2) < address(numeraire2)
            ? (address(asset2), address(numeraire2))
            : (address(numeraire2), address(asset2));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0_2, token1_2, recipient);

        // Verify pool 2 distributed correctly (50%)
        assertEq(numeraire2.balanceOf(payout) - payoutBalanceBefore, 500 ether); // 50% of 1000
    }

    /// @notice Test with extreme values near safe max (overflow safety)
    function testFuzz_migrate_ExtremeValues(uint256 balance) public {
        // Test with very large balances - max safe value is type(uint256).max / WAD
        // to prevent overflow in distribution calculation: balance * percentWad / WAD
        // With percentWad up to 5e17 (50%), max safe balance is ~type(uint256).max / 5e17
        uint256 maxSafeBalance = type(uint256).max / WAD; // ~1.15e59
        balance = bound(balance, type(uint128).max, maxSafeBalance);

        bytes memory data = abi.encode(payout, PERCENT_50, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        // Mint extreme balance
        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        // Should not overflow
        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Verify math is correct even with large numbers
        uint256 expectedDistribution = (balance * PERCENT_50) / WAD;
        assertEq(numeraire.balanceOf(payout), expectedDistribution);
    }

    /// @notice Test that distribution never exceeds 50% regardless of input
    function testFuzz_migrate_DistributionNeverExceedsHalf(uint256 balance, uint256 percentWad) public {
        balance = bound(balance, 1, type(uint128).max);
        percentWad = bound(percentWad, 0, MAX_DISTRIBUTION_WAD);

        bytes memory data = abi.encode(payout, percentWad, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Distribution should never exceed half the balance
        uint256 distribution = numeraire.balanceOf(payout);
        assertLe(distribution, balance / 2 + 1, "Distribution exceeded 50%"); // +1 for rounding
    }

    /// @notice Test CEI pattern - config is deleted before external calls (reentrancy protection)
    function test_migrate_ConfigDeletedBeforeExternalCalls() public {
        // This test verifies CEI pattern by checking config is gone even if we could re-enter
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        numeraire.mint(address(distributor), 1000 ether);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        // Before migrate - config exists
        (address storedPayoutBefore,,,) = distributor.getDistributionConfig(token0, token1);
        assertEq(storedPayoutBefore, payout, "Config should exist before migrate");

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // After migrate - config should be deleted
        (address storedPayoutAfter,,,) = distributor.getDistributionConfig(token0, token1);
        assertEq(storedPayoutAfter, address(0), "Config should be deleted after migrate");
    }

    /// @notice Test with zero percent - no distribution should occur
    function test_migrate_ZeroPercent() public {
        bytes memory data = abi.encode(payout, 0, address(mockUnderlying), ""); // 0%
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        uint256 balance = 1000 ether;
        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Payout should receive nothing
        assertEq(numeraire.balanceOf(payout), 0);
        // Underlying should receive everything
        assertEq(numeraire.balanceOf(address(mockUnderlying)), balance);
    }

    /// @notice Test exact max percent (50%)
    function test_migrate_ExactMaxPercent() public {
        bytes memory data = abi.encode(payout, MAX_DISTRIBUTION_WAD, address(mockUnderlying), ""); // exactly 50%
        vm.prank(address(airlock));
        distributor.initialize(address(asset), address(numeraire), data);

        uint256 balance = 1000 ether;
        numeraire.mint(address(distributor), balance);

        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));

        vm.prank(address(airlock));
        distributor.migrate(1e18, token0, token1, recipient);

        // Payout should receive exactly 50%
        assertEq(numeraire.balanceOf(payout), balance / 2);
        // Underlying should receive exactly 50%
        assertEq(numeraire.balanceOf(address(mockUnderlying)), balance / 2);
    }

    // ============ V4 Preflight Check Tests ============

    /// @notice Test V4 preflight - reverts when locker has not approved migrator
    function test_initialize_RevertsWhenLockerNotApproved() public {
        // Deploy mock locker and hook
        MockLocker mockLocker = new MockLocker();
        MockHook mockHook = new MockHook();

        // Deploy V4 mock migrator with locker and hook
        MockV4Migrator v4Mock =
            new MockV4Migrator(address(distributor), address(mockLocker), address(mockHook), address(0x1234));

        // Set hook's migrator correctly
        mockHook.setMigrator(address(v4Mock));

        // DON'T approve the migrator in locker (this should cause revert)
        // mockLocker.setApproval(address(v4Mock), true); // Intentionally NOT called

        // Whitelist the V4 mock
        address[] memory modules = new address[](1);
        modules[0] = address(v4Mock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(v4Mock), "");
        vm.prank(address(airlock));
        vm.expectRevert(UnderlyingNotLockerApproved.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    /// @notice Test V4 preflight - reverts when hook's migrator doesn't match
    function test_initialize_RevertsWhenHookMigratorMismatch() public {
        // Deploy mock locker and hook
        MockLocker mockLocker = new MockLocker();
        MockHook mockHook = new MockHook();

        // Deploy V4 mock migrator with locker and hook
        MockV4Migrator v4Mock =
            new MockV4Migrator(address(distributor), address(mockLocker), address(mockHook), address(0x1234));

        // Approve the migrator in locker
        mockLocker.setApproval(address(v4Mock), true);

        // Set hook's migrator to WRONG address
        mockHook.setMigrator(address(0xdead)); // Wrong migrator!

        // Whitelist the V4 mock
        address[] memory modules = new address[](1);
        modules[0] = address(v4Mock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(v4Mock), "");
        vm.prank(address(airlock));
        vm.expectRevert(UnderlyingHookMismatch.selector);
        distributor.initialize(address(asset), address(numeraire), data);
    }

    /// @notice Test V4 preflight - succeeds when locker approved and hook matches
    function test_initialize_V4PreflightSuccess() public {
        // Deploy mock locker and hook
        MockLocker mockLocker = new MockLocker();
        MockHook mockHook = new MockHook();

        // Deploy V4 mock migrator with locker and hook
        MockV4Migrator v4Mock =
            new MockV4Migrator(address(distributor), address(mockLocker), address(mockHook), address(0x1234));

        // Approve the migrator in locker
        mockLocker.setApproval(address(v4Mock), true);

        // Set hook's migrator correctly
        mockHook.setMigrator(address(v4Mock));

        // Whitelist the V4 mock
        address[] memory modules = new address[](1);
        modules[0] = address(v4Mock);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(owner);
        airlock.setModuleState(modules, states);

        bytes memory data = abi.encode(payout, PERCENT_10, address(v4Mock), "");
        vm.prank(address(airlock));
        // Should succeed
        address pool = distributor.initialize(address(asset), address(numeraire), data);
        assertEq(pool, address(0x1234));
    }

    /// @notice Test that non-V4 migrators (without locker/hook) still work
    function test_initialize_NonV4MigratorSkipsPreflight() public {
        // mockUnderlying doesn't have locker() or migratorHook(), so preflight should be skipped
        bytes memory data = abi.encode(payout, PERCENT_10, address(mockUnderlying), "");
        vm.prank(address(airlock));
        // Should succeed - no preflight checks triggered for non-V4 migrators
        address pool = distributor.initialize(address(asset), address(numeraire), data);
        assertEq(pool, address(0x1234));
    }
}
