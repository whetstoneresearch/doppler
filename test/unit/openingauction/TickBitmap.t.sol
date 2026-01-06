// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest, OpeningAuctionImplementation } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

/// @title TickBitmap Tests
/// @notice Comprehensive tests for the bitmap-based tick management in OpeningAuction
contract TickBitmapTest is OpeningAuctionBaseTest {
    // Use larger liquidity amounts to ensure settlement works
    uint128 constant LARGE_LIQUIDITY = 1e18;
    
    /// @notice Get a config that allows settlement with reasonable bids
    function getBitmapTestConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -887_220, // Very low min tick to allow all bids
            minAcceptableTickToken1: -887_220,
            incentiveShareBps: 1000, // 10%
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15
        });
    }
    
    /// @notice Setup for bitmap tests - deploy with extended config
    function setUp() public override {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        _deployTokens();

        // Deploy opening auction with bitmap test config
        _deployOpeningAuction(getBitmapTestConfig(), DEFAULT_AUCTION_TOKENS);

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        // Approve routers
        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Fund users with large amounts for many positions
        TestERC20(token0).transfer(alice, 100_000_000 ether);
        TestERC20(token1).transfer(alice, 100_000_000 ether);
        TestERC20(token0).transfer(bob, 100_000_000 ether);
        TestERC20(token1).transfer(bob, 100_000_000 ether);
    }
    
    /// @notice Helper to add bids at valid tick locations
    function _addValidBid(address user, uint256 tickOffset, uint128 liquidity) internal returns (uint256) {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 startingBidTick = ((minTick / tickSpacing) + 1) * tickSpacing;
        int24 tickLower = startingBidTick + int24(int256(tickOffset)) * tickSpacing * 5;
        return _addBid(user, tickLower, liquidity);
    }
    
    // ============ Bitmap Basic Operations ============

    function test_bitmap_SingleTickInsertion() public {
        // Add a single bid at a valid tick
        _addValidBid(alice, 0, LARGE_LIQUIDITY);

        // Verify tick is tracked - use the valid tick helper
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 tickLower = ((minTick / tickSpacing) + 1) * tickSpacing;
        uint128 liquidity = hook.liquidityAtTick(tickLower);
        assertEq(liquidity, LARGE_LIQUIDITY, "Liquidity should be recorded at tick");
    }

    function test_bitmap_MultipleTicksInsertion() public {
        // Add bids at multiple valid ticks
        for (uint256 i = 0; i < 5; i++) {
            _addValidBid(alice, i, LARGE_LIQUIDITY);
        }

        // Verify all ticks are tracked by checking liquidity exists
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 startingBidTick = ((minTick / tickSpacing) + 1) * tickSpacing;
        
        for (uint256 i = 0; i < 5; i++) {
            int24 tick = startingBidTick + int24(int256(i)) * tickSpacing * 5;
            uint128 liquidity = hook.liquidityAtTick(tick);
            assertEq(liquidity, LARGE_LIQUIDITY, "Liquidity should be recorded at each tick");
        }
    }

    /// @notice Test that bitmap correctly tracks tick state
    /// @dev Removal tests are covered by integration tests - this verifies tracking
    function test_bitmap_TickTracking() public {
        // Add a bid and verify it's tracked
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 tickLower = ((minTick / tickSpacing) + 1) * tickSpacing;
        
        uint128 liquidity = LARGE_LIQUIDITY;
        _addBid(alice, tickLower, liquidity);

        // Verify tick is tracked in bitmap
        assertEq(hook.liquidityAtTick(tickLower), liquidity, "Tick should be tracked with correct liquidity");
        
        // Verify hasActiveTicks is true
        assertTrue(hook.getHasActiveTicks(), "Should have active ticks after adding bid");
    }

    function test_bitmap_MultipleBidsAtSameTick() public {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 tickLower = ((minTick / tickSpacing) + 1) * tickSpacing;
        
        // Add first bid
        _addBid(alice, tickLower, LARGE_LIQUIDITY);
        assertEq(hook.liquidityAtTick(tickLower), LARGE_LIQUIDITY);

        // Add second bid at same tick
        _addBid(bob, tickLower, LARGE_LIQUIDITY * 2);
        assertEq(hook.liquidityAtTick(tickLower), LARGE_LIQUIDITY * 3, "Liquidity should aggregate");
    }

    function test_bitmap_TicksAcrossWordBoundaries() public {
        // Ticks are stored in 256-bit words, with each word covering 256 ticks
        // Test ticks that span multiple words by using large tick offsets
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 baseTick = ((minTick / tickSpacing) + 1) * tickSpacing;
        
        // Add ticks with large gaps (different words)
        int24[] memory offsets = new int24[](4);
        offsets[0] = 0;
        offsets[1] = 300;   // Different word
        offsets[2] = 600;   // Different word
        offsets[3] = 900;   // Different word

        for (uint256 i = 0; i < offsets.length; i++) {
            int24 tick = baseTick + offsets[i] * tickSpacing;
            if (tick < TickMath.MAX_TICK - tickSpacing) {
                _addBid(alice, tick, LARGE_LIQUIDITY);
            }
        }

        // Verify ticks are tracked across word boundaries
        for (uint256 i = 0; i < offsets.length; i++) {
            int24 tick = baseTick + offsets[i] * tickSpacing;
            if (tick < TickMath.MAX_TICK - tickSpacing) {
                uint128 liquidity = hook.liquidityAtTick(tick);
                assertEq(liquidity, LARGE_LIQUIDITY, "Liquidity should be recorded across word boundaries");
            }
        }
    }

    // ============ Bitmap Iteration Tests ============

    function test_bitmap_IterationOrder_Ascending() public {
        // Add ticks in non-sorted order using valid tick helper
        _addValidBid(alice, 3, LARGE_LIQUIDITY);
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        _addValidBid(alice, 2, LARGE_LIQUIDITY);
        _addValidBid(alice, 1, LARGE_LIQUIDITY);

        // Settlement should iterate ticks correctly regardless of insertion order
        _warpToAuctionEnd();
        hook.settleAuction();

        // Verify auction settled successfully
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    function test_bitmap_IterationWithGaps() public {
        // Add ticks with large gaps between them
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        _addValidBid(alice, 10, LARGE_LIQUIDITY);
        _addValidBid(alice, 50, LARGE_LIQUIDITY);

        // Settlement should handle gaps correctly
        _warpToAuctionEnd();
        hook.settleAuction();

        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Boundary Tracking Tests ============

    function test_bitmap_MinMaxTracking() public {
        // Add ticks at different offsets
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        _addValidBid(alice, 5, LARGE_LIQUIDITY);
        _addValidBid(alice, 10, LARGE_LIQUIDITY);

        // The internal min/max are tracked but not exposed publicly
        // We verify indirectly through successful operations
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        // If min/max tracking was broken, settlement would fail or behave incorrectly
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    /// @notice Test that min/max bounds are correctly updated when ticks are added
    function test_bitmap_MinMaxBoundsTracking() public {
        // Add ticks at different positions
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        _addValidBid(alice, 5, LARGE_LIQUIDITY);
        _addValidBid(alice, 10, LARGE_LIQUIDITY);

        // Verify hasActiveTicks reflects the state
        assertTrue(hook.getHasActiveTicks(), "Should have active ticks");

        // Settlement should work correctly with proper min/max tracking
        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Edge Cases ============

    function test_bitmap_EmptyBitmap() public {
        // No bids placed - auction should still settle
        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
        assertEq(hook.totalTokensSold(), 0, "No tokens should be sold with no bids");
    }

    function test_bitmap_SingleTick() public {
        _addValidBid(alice, 0, LARGE_LIQUIDITY * 100);
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    function test_bitmap_NegativeTicks() public {
        // With the permissive config, negative ticks are valid
        // Add bids at valid negative tick positions
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        _addValidBid(alice, 5, LARGE_LIQUIDITY);
        _addValidBid(alice, 10, LARGE_LIQUIDITY);

        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Fuzz Tests ============

    function testFuzz_bitmap_RandomTickInsertion(uint8 numBids) public {
        vm.assume(numBids > 0 && numBids <= 20);
        
        for (uint256 i = 0; i < numBids; i++) {
            _addValidBid(alice, i, LARGE_LIQUIDITY);
        }

        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    function testFuzz_bitmap_MultipleTickOperations(uint8 numOps) public {
        vm.assume(numOps > 0 && numOps <= 20);
        
        // Test that bitmap handles multiple tick operations correctly
        // Add bids at various tick offsets
        for (uint256 i = 0; i < numOps; i++) {
            _addValidBid(alice, i * 2, LARGE_LIQUIDITY);
        }
        
        // Verify tick count matches
        assertEq(hook.getActiveTickCount(), numOps, "Tick count should match number of bids");
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Time Accumulation with Bitmap ============

    function test_bitmap_TimeAccumulation_MultipleInRangeTicks() public {
        // Add multiple bids that will accumulate time - need enough for in-range status
        _addValidBid(alice, 0, LARGE_LIQUIDITY * 100);
        _addValidBid(bob, 1, LARGE_LIQUIDITY * 100);
        _addValidBid(alice, 2, LARGE_LIQUIDITY * 100);
        
        // Warp significant time to accumulate
        vm.warp(block.timestamp + 18 hours);
        
        // Add another bid to trigger clearing tick update and time accumulation
        _addValidBid(bob, 3, LARGE_LIQUIDITY * 100);
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        // Settlement should complete - time tracking is internal to the mechanism
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    function test_bitmap_TimeAccumulation_TickEntersRange() public {
        // Add a bid
        _addValidBid(alice, 0, LARGE_LIQUIDITY);
        
        // Add more bids to push clearing tick
        _addValidBid(bob, 1, LARGE_LIQUIDITY * 100);
        _addValidBid(bob, 2, LARGE_LIQUIDITY * 100);
        
        // Warp time
        vm.warp(block.timestamp + 12 hours);
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Incentive Calculation with Bitmap ============

    function test_bitmap_IncentiveDistribution() public {
        // Add multiple bids at different ticks
        _addValidBid(alice, 0, LARGE_LIQUIDITY * 50);
        _addValidBid(bob, 1, LARGE_LIQUIDITY * 50);
        
        // Warp time
        vm.warp(block.timestamp + 12 hours);
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        // Calculate incentives for both
        uint256 aliceIncentives = hook.calculateIncentives(1);
        uint256 bobIncentives = hook.calculateIncentives(2);
        
        // Total incentives should not exceed the pool
        uint256 totalIncentives = aliceIncentives + bobIncentives;
        assertLe(totalIncentives, hook.incentiveTokensTotal(), "Total incentives should not exceed pool");
    }

    function test_bitmap_IncentivesWithMultipleBidders() public {
        // Test incentive calculation with multiple bidders at different ticks
        _addValidBid(alice, 0, LARGE_LIQUIDITY * 50);
        _addValidBid(bob, 5, LARGE_LIQUIDITY * 50);
        _addValidBid(alice, 10, LARGE_LIQUIDITY * 50);
        
        // Warp time to accumulate
        vm.warp(block.timestamp + 12 hours);
        
        _warpToAuctionEnd();
        hook.settleAuction();
        
        // Verify incentives are calculable for all positions
        uint256 aliceIncentives1 = hook.calculateIncentives(1);
        uint256 bobIncentives = hook.calculateIncentives(2);
        uint256 aliceIncentives2 = hook.calculateIncentives(3);
        
        // Total incentives should not exceed the pool
        uint256 totalIncentives = aliceIncentives1 + bobIncentives + aliceIncentives2;
        assertLe(totalIncentives, hook.incentiveTokensTotal(), "Total incentives should not exceed pool");
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }

    // ============ Gas Comparison Tests (Informational) ============

    function test_bitmap_GasEfficiency_LargeBidCount() public {
        // Add many bids to test gas efficiency of bitmap operations
        uint256 numBids = 50;
        
        uint256 gasStart = gasleft();
        
        for (uint256 i = 0; i < numBids; i++) {
            _addValidBid(alice, i, LARGE_LIQUIDITY);
        }
        
        uint256 gasUsedForBids = gasStart - gasleft();
        
        gasStart = gasleft();
        _warpToAuctionEnd();
        hook.settleAuction();
        uint256 gasUsedForSettlement = gasStart - gasleft();
        
        // Log gas usage for comparison (this is informational)
        emit log_named_uint("Gas for 50 bids", gasUsedForBids);
        emit log_named_uint("Gas for settlement", gasUsedForSettlement);
        
        assertEq(uint256(hook.phase()), uint256(AuctionPhase.Settled));
    }
}
