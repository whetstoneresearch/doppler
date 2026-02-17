// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @title OpeningAuctionGas
/// @notice Gas benchmark tests for OpeningAuction settlement with varying numbers of active ticks
/// @dev Settlement iterates over activeTicks array in _finalizeAllTickTimes
///      These benchmarks help assess the practical gas limits for settlement
contract OpeningAuctionGas is OpeningAuctionBaseTest {
    // Use larger liquidity amounts to ensure positions are in range
    uint128 constant LARGE_LIQUIDITY = 1e18;

    /// @notice Get a config with longer auction duration for gas tests
    function getGasTestConfig() public pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 7 days,
            minAcceptableTickToken0: -887_220, // Very low min tick to allow all bids
            minAcceptableTickToken1: -887_220,
            incentiveShareBps: 1000, // 10%
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });
    }

    /// @notice Helper to add N bids spread across the valid tick range
    /// @param numTicks Number of unique tick positions to create
    function _addBidsAtUniqueTicks(uint256 numTicks) internal {
        // For isToken0=true, valid ticks are >= minAcceptableTick
        // We spread bids from minAcceptableTick upward
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        // Start from just above the minimum acceptable tick
        // Align to tick spacing
        int24 startingBidTick = ((minTick / tickSpacing) + 1) * tickSpacing;

        // Spread ticks upward with a reasonable step
        // Use a step that ensures we have enough room for all ticks
        int24 step = tickSpacing * 5; // 5 tick spacings between each position

        for (uint256 i = 0; i < numTicks; i++) {
            int24 tickLower = startingBidTick + int24(int256(i)) * step;

            // Ensure we don't exceed MAX_TICK
            if (tickLower >= TickMath.MAX_TICK - tickSpacing) {
                break;
            }

            // Add bid at this tick
            _addBid(alice, tickLower, LARGE_LIQUIDITY);
        }
    }

    /// @notice Setup for gas tests - deploy with extended config
    function setUp() public override {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        _deployTokens();

        // Deploy router before hook so we can authorize it
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        // Deploy opening auction with gas test config
        _deployOpeningAuction(getGasTestConfig(), DEFAULT_AUCTION_TOKENS);
        vm.prank(initializer);
        hook.setPositionManager(address(modifyLiquidityRouter));

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        // Approve routers
        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Fund users with large amounts for many positions
        TestERC20(token0).transfer(alice, 100_000_000 ether);
        TestERC20(token1).transfer(alice, 100_000_000 ether);
    }

    // ============ Gas Benchmark Tests ============

    /// @notice Benchmark settlement gas with 1 active tick
    function test_gas_settlement_1Tick() public {
        _addBidsAtUniqueTicks(1);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 1 tick:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_1Tick");
    }

    /// @notice Benchmark settlement gas with 5 active ticks
    function test_gas_settlement_5Ticks() public {
        _addBidsAtUniqueTicks(5);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 5 ticks:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_5Ticks");
    }

    /// @notice Benchmark settlement gas with 10 active ticks
    function test_gas_settlement_10Ticks() public {
        _addBidsAtUniqueTicks(10);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 10 ticks:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_10Ticks");
    }

    /// @notice Benchmark settlement gas with 25 active ticks
    function test_gas_settlement_25Ticks() public {
        _addBidsAtUniqueTicks(25);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 25 ticks:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_25Ticks");
    }

    /// @notice Benchmark settlement gas with 50 active ticks
    function test_gas_settlement_50Ticks() public {
        _addBidsAtUniqueTicks(50);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 50 ticks:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_50Ticks");
    }

    /// @notice Benchmark settlement gas with 100 active ticks
    function test_gas_settlement_100Ticks() public {
        _addBidsAtUniqueTicks(100);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 100 ticks:", gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", "Settlement_100Ticks");
    }

    /// @notice Fuzz test to measure gas across a range of tick counts
    /// @param numTicks Number of ticks (bounded to prevent timeout)
    function testFuzz_gas_settlement(uint8 numTicks) public {
        // Bound to reasonable range to prevent timeout
        uint256 tickCount = bound(numTicks, 1, 100);

        _addBidsAtUniqueTicks(tickCount);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        // Log results for analysis
        console.log("Tick count:", tickCount, "| Gas used:", gasUsed);

        // Calculate approximate gas per tick (excluding base overhead)
        // Base overhead is roughly the gas with 1 tick
        if (tickCount > 1) {
            uint256 gasPerTick = gasUsed / tickCount;
            console.log("Approximate gas per tick:", gasPerTick);
        }
    }

    /// @notice Summary test that logs benchmark overview
    /// @dev Cannot re-deploy within a single test, so this just runs the max tick scenario
    ///      and calculates approximate gas scaling. Run individual tests for full results.
    function test_gas_settlement_summary() public {
        console.log("=== OpeningAuction Settlement Gas Benchmark ===");
        console.log("");
        console.log("Run individual tests for detailed results:");
        console.log("  forge test --match-test 'test_gas_settlement_.*Tick' -vv");
        console.log("");

        // Run with max ticks for this test
        _addBidsAtUniqueTicks(100);
        _warpToAuctionEnd();

        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Settlement gas with 100 ticks:", gasUsed);
        console.log("Average gas per tick:", gasUsed / 100);
        console.log("");
        console.log("Expected scaling (based on individual test runs):");
        console.log("  1 tick:   ~1,283,788 gas (base cost)");
        console.log("  5 ticks:  ~1,290,780 gas");
        console.log("  10 ticks: ~1,300,896 gas");
        console.log("  25 ticks: ~1,328,236 gas");
        console.log("  50 ticks: ~1,364,393 gas");
        console.log("  100 ticks: ~1,447,034 gas");
        console.log("");
        console.log("Marginal cost per additional tick: ~1,650 gas");
    }
}
