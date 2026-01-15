// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
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
    UnderlyingNotForwarded,
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
}
