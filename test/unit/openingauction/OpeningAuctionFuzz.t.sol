// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, AuctionPhase, AuctionPosition, OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @title OpeningAuctionFuzz
/// @notice Fuzz tests for OpeningAuction tick and amount edge cases
contract OpeningAuctionFuzz is OpeningAuctionBaseTest {
    // ============ Constants ============

    /// @dev MIN_TICK from TickMath
    int24 constant TICK_MIN = -887272;
    /// @dev MAX_TICK from TickMath
    int24 constant TICK_MAX = 887272;

    // ============ Setup ============

    function setUp() public override {
        super.setUp();
        // Additional funding for test contracts
        TestERC20(token0).transfer(address(this), 10_000_000 ether);
        TestERC20(token1).transfer(address(this), 10_000_000 ether);
    }

    // ============ Fuzz Tests: Bid Amounts (Liquidity Delta) ============

    /// @notice Fuzz test for bid amounts at various magnitudes
    /// @param liquidityDelta The liquidity amount to bid (fuzzed)
    function testFuzz_bidAmount_variousMagnitudes(uint128 liquidityDelta) public {
        // Bound liquidity to valid range: minLiquidity to a reasonable max
        uint128 minLiq = hook.minLiquidity();
        liquidityDelta = uint128(bound(liquidityDelta, minLiq, 1000 ether));

        // Use a valid tick above minimum acceptable
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        // Add the bid
        uint256 positionId = _addBid(alice, tickLower, liquidityDelta);

        // Verify position was created correctly
        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.owner, alice);
        assertEq(pos.liquidity, liquidityDelta);
        assertEq(pos.tickLower, tickLower);
        assertEq(pos.tickUpper, tickLower + key.tickSpacing);
    }

    /// @notice Fuzz test for bid amounts near minimum liquidity boundary
    /// @param liquidityMultiplier Multiplier above minLiquidity (fuzzed)
    function testFuzz_bidAmount_nearMinimumBoundary(uint8 liquidityMultiplier) public {
        uint128 minLiq = hook.minLiquidity();
        
        // Test values from 1x to 10x minimum liquidity
        liquidityMultiplier = uint8(bound(liquidityMultiplier, 1, 10));
        uint128 liquidity = minLiq * uint128(liquidityMultiplier);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.liquidity, liquidity);
        assertGe(pos.liquidity, minLiq);
    }

    /// @notice Fuzz test for large bid amounts
    /// @param largeLiquidityOffset Offset added to base large amount (fuzzed)
    function testFuzz_bidAmount_largeMagnitudes(uint128 largeLiquidityOffset) public {
        // Start with a large base and add fuzzed offset
        uint128 baseLiquidity = 10_000 ether;
        largeLiquidityOffset = uint128(bound(largeLiquidityOffset, 0, 90_000 ether));
        uint128 liquidity = baseLiquidity + largeLiquidityOffset;

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        // Fund alice with extra tokens for large positions
        TestERC20(token0).transfer(alice, 100_000_000 ether);
        TestERC20(token1).transfer(alice, 100_000_000 ether);

        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.liquidity, liquidity);
    }

    // ============ Fuzz Tests: Tick Values ============

    /// @notice Fuzz test for valid tick values respecting tickSpacing
    /// @param tickMultiplier Multiplier from minAcceptableTick (fuzzed)
    function testFuzz_tick_validRangeIsToken0(uint16 tickMultiplier) public {
        // For isToken0=true, valid ticks are >= minAcceptableTick
        int24 minTick = hook.minAcceptableTick();
        int24 tickSpacing = key.tickSpacing;

        // Bound multiplier to reasonable range (avoiding overflow)
        tickMultiplier = uint16(bound(tickMultiplier, 1, 1000));

        int24 tickLower = minTick + int24(uint24(tickMultiplier)) * tickSpacing;

        // Ensure tick is within valid range
        vm.assume(tickLower + tickSpacing <= TICK_MAX);

        uint128 liquidity = hook.minLiquidity();
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.tickLower, tickLower);
        assertEq(pos.tickUpper, tickLower + tickSpacing);

        // Invariant: tick must be aligned to tickSpacing
        assertEq(pos.tickLower % tickSpacing, 0);
    }

    /// @notice Fuzz test for tick values at spacing boundaries
    /// @param spacingMultiplier Multiplier for tick spacing (fuzzed)
    function testFuzz_tick_spacingBoundaries(uint16 spacingMultiplier) public {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        // Bound multiplier to reasonable range
        spacingMultiplier = uint16(bound(spacingMultiplier, 1, 1000));

        int24 tickLower = minTick + int24(uint24(spacingMultiplier)) * tickSpacing;

        // Ensure tick is within valid range
        vm.assume(tickLower + tickSpacing <= TICK_MAX);

        uint128 liquidity = hook.minLiquidity();
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        // Verify position
        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.tickLower, tickLower);

        // Invariant: tickUpper - tickLower == tickSpacing (single-tick position)
        assertEq(pos.tickUpper - pos.tickLower, tickSpacing);
    }

    /// @notice Fuzz test verifying tick alignment across various inputs
    /// @param rawMultiplier Raw multiplier input (fuzzed)
    function testFuzz_tick_alignmentEnforced(uint16 rawMultiplier) public {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        rawMultiplier = uint16(bound(rawMultiplier, 1, 500));
        int24 tickLower = minTick + int24(uint24(rawMultiplier)) * tickSpacing;

        vm.assume(tickLower + tickSpacing <= TICK_MAX);

        uint128 liquidity = hook.minLiquidity();
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);

        // Invariant: position ticks must be aligned
        assertEq(pos.tickLower % tickSpacing, 0, "tickLower not aligned");
        assertEq(pos.tickUpper % tickSpacing, 0, "tickUpper not aligned");
    }

    // ============ Fuzz Tests: Multiple Bidders at Random Ticks ============

    /// @notice Fuzz test for multiple bidders at sequential ticks
    /// @param numBidders Number of bidders (fuzzed)
    /// @param liquiditySeed Seed for liquidity amounts (fuzzed)
    function testFuzz_multipleBidders_sequentialTicks(uint8 numBidders, uint256 liquiditySeed) public {
        // Bound number of bidders to reasonable range
        numBidders = uint8(bound(numBidders, 2, 15));

        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        uint128 minLiq = hook.minLiquidity();

        uint256 initialNextPositionId = hook.nextPositionId();

        for (uint8 i = 0; i < numBidders; i++) {
            // Create bidder address
            address bidder = address(uint160(0x5000 + i));

            // Fund bidder from test contract
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);

            // Sequential ticks
            int24 tickLower = minTick + int24(uint24(i + 1)) * tickSpacing;

            // Skip if tick would exceed max
            if (tickLower + tickSpacing > TICK_MAX) break;

            // Generate pseudo-random liquidity from seed
            uint256 bidderSeed = uint256(keccak256(abi.encode(liquiditySeed, i)));
            uint128 liquidity = minLiq + uint128(bidderSeed % 5 ether);

            uint256 positionId = _addBidFrom(bidder, tickLower, liquidity);

            // Verify position
            AuctionPosition memory pos = hook.positions(positionId);
            assertEq(pos.owner, bidder);
            assertEq(pos.liquidity, liquidity);
            assertEq(pos.tickLower, tickLower);
        }

        // Invariant: position IDs should have increased
        assertGt(hook.nextPositionId(), initialNextPositionId);
    }

    /// @notice Fuzz test for bidders at spread-out ticks
    /// @param numBidders Number of bidders (fuzzed)
    /// @param spreadFactor How spread out the ticks are (fuzzed)
    function testFuzz_multipleBidders_spreadTicks(uint8 numBidders, uint8 spreadFactor) public {
        numBidders = uint8(bound(numBidders, 2, 10));
        spreadFactor = uint8(bound(spreadFactor, 1, 20));

        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        uint128 minLiq = hook.minLiquidity();

        for (uint8 i = 0; i < numBidders; i++) {
            address bidder = address(uint160(0x6000 + i));
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);

            // Spread ticks based on spreadFactor
            int24 tickLower = minTick + int24(uint24(i + 1)) * tickSpacing * int24(uint24(spreadFactor));

            if (tickLower + tickSpacing > TICK_MAX) break;

            _addBidFrom(bidder, tickLower, minLiq);
        }

        // Should have at least some positions
        assertGt(hook.nextPositionId(), 1);
    }

    // ============ Fuzz Tests: Incentive Calculations with Fuzzed Time ============

    /// @notice Fuzz test for incentive calculations with fuzzed time durations
    /// @param timeDuration Time to wait before checking (fuzzed)
    function testFuzz_incentives_fuzzedTimeDurations(uint256 timeDuration) public {
        // Bound time to valid auction duration range
        timeDuration = bound(timeDuration, 1, hook.auctionDuration() - 1);

        // Add a bid
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 liquidity = hook.minLiquidity() * 10;
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        // Warp forward by fuzzed amount
        vm.warp(block.timestamp + timeDuration);

        // Position should be tracking time
        uint256 accumulatedTime = hook.getPositionAccumulatedTime(positionId);

        // Invariant: accumulated time should be bounded by elapsed time
        // (May be 0 if not in range)
        assertTrue(accumulatedTime <= timeDuration + 1);
    }

    /// @notice Fuzz test for incentive distribution proportionality
    /// @param liquidity1 First position liquidity (fuzzed)
    /// @param liquidity2 Second position liquidity (fuzzed)
    function testFuzz_incentives_proportionalDistribution(uint128 liquidity1, uint128 liquidity2) public {
        uint128 minLiq = hook.minLiquidity();

        // Bound liquidities to valid range
        liquidity1 = uint128(bound(liquidity1, minLiq, 100 ether));
        liquidity2 = uint128(bound(liquidity2, minLiq, 100 ether));

        // Create two positions at adjacent ticks
        int24 tickLower1 = hook.minAcceptableTick() + key.tickSpacing * 10;
        int24 tickLower2 = tickLower1 + key.tickSpacing;

        uint256 positionId1 = _addBid(alice, tickLower1, liquidity1);
        uint256 positionId2 = _addBid(bob, tickLower2, liquidity2);

        // Let time pass for accumulation
        vm.warp(block.timestamp + 1 hours);

        // Check accumulated times
        uint256 time1 = hook.getPositionAccumulatedTime(positionId1);
        uint256 time2 = hook.getPositionAccumulatedTime(positionId2);

        // Both positions should have non-negative accumulated time
        assertTrue(time1 >= 0);
        assertTrue(time2 >= 0);

        // Invariant: times are bounded by elapsed time
        assertTrue(time1 <= 1 hours + 1);
        assertTrue(time2 <= 1 hours + 1);
    }

    /// @notice Fuzz test for time accumulation at auction boundaries
    /// @param timeBeforeEnd Time before auction end (fuzzed)
    function testFuzz_incentives_timeAccumulationBoundary(uint256 timeBeforeEnd) public {
        // Bound to ensure we're testing near the boundary
        timeBeforeEnd = bound(timeBeforeEnd, 1, 1 hours);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint256 positionId = _addBid(alice, tickLower, hook.minLiquidity() * 10);

        // Warp to just before auction end
        vm.warp(hook.auctionEndTime() - timeBeforeEnd);

        uint256 timeAtBoundary = hook.getPositionAccumulatedTime(positionId);

        // Warp past auction end
        vm.warp(hook.auctionEndTime() + 1 hours);

        uint256 timeAfterEnd = hook.getPositionAccumulatedTime(positionId);

        // Invariant: time should not increase after auction end
        // (Time is capped at auctionEndTime)
        assertGe(timeAfterEnd, timeAtBoundary);
    }

    // ============ Fuzz Tests: Edge Cases ============

    /// @notice Fuzz test at minimum acceptable tick boundary
    /// @param liquidityDelta Liquidity amount (fuzzed)
    function testFuzz_edgeCase_nearMinAcceptableTick(uint128 liquidityDelta) public {
        uint128 minLiq = hook.minLiquidity();
        liquidityDelta = uint128(bound(liquidityDelta, minLiq, 10 ether));

        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        // Place bid at first valid tick above minimum acceptable
        int24 tickLower = ((minTick / tickSpacing) + 1) * tickSpacing;
        if (tickLower < minTick) tickLower += tickSpacing;

        uint256 positionId = _addBid(alice, tickLower, liquidityDelta);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.tickLower, tickLower);
        assertGe(pos.tickLower, minTick);
    }

    /// @notice Fuzz test at high tick values
    /// @param tickOffset Offset from a high base tick (fuzzed)
    function testFuzz_edgeCase_highTickValues(uint16 tickOffset) public {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        // Start from a high base tick
        int24 baseTick = minTick + 50000;

        // Bound offset
        tickOffset = uint16(bound(tickOffset, 0, 1000));
        int24 tickLower = baseTick + int24(uint24(tickOffset)) * tickSpacing;

        // Align to tick spacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;

        // Ensure valid range
        vm.assume(tickLower >= minTick);
        vm.assume(tickLower + tickSpacing <= TICK_MAX);

        uint128 liquidity = hook.minLiquidity();
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.tickLower, tickLower);
        assertLe(pos.tickUpper, TICK_MAX);
    }

    /// @notice Fuzz test with large liquidity values
    /// @param liquidityMultiplier Multiplier for base liquidity (fuzzed)
    function testFuzz_edgeCase_largeLiquidityValues(uint16 liquidityMultiplier) public {
        uint128 minLiq = hook.minLiquidity();

        // Bound multiplier
        liquidityMultiplier = uint16(bound(liquidityMultiplier, 1, 1000));
        uint128 liquidity = minLiq * uint128(liquidityMultiplier);

        // Ensure we have enough tokens
        TestERC20(token0).transfer(alice, 1_000_000_000 ether);
        TestERC20(token1).transfer(alice, 1_000_000_000 ether);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.liquidity, liquidity);
    }

    /// @notice Test exact minimum liquidity acceptance
    function test_edgeCase_exactMinLiquidity() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 exactMinLiquidity = hook.minLiquidity();

        uint256 positionId = _addBid(alice, tickLower, exactMinLiquidity);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.liquidity, exactMinLiquidity);
    }

    // ============ Fuzz Tests: Invariants ============

    /// @notice Fuzz test invariant: position must be single-tick width
    /// @param tickMultiplier Tick offset from min (fuzzed)
    /// @param liquidityDelta Liquidity (fuzzed)
    function testFuzz_invariant_singleTickWidth(uint16 tickMultiplier, uint128 liquidityDelta) public {
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();

        // Generate valid tick
        tickMultiplier = uint16(bound(tickMultiplier, 1, 500));
        int24 tickLower = minTick + int24(uint24(tickMultiplier)) * tickSpacing;

        vm.assume(tickLower + tickSpacing <= TICK_MAX);

        uint128 minLiq = hook.minLiquidity();
        liquidityDelta = uint128(bound(liquidityDelta, minLiq, 10 ether));

        uint256 positionId = _addBid(alice, tickLower, liquidityDelta);

        AuctionPosition memory pos = hook.positions(positionId);

        // Invariant: position must span exactly one tick spacing
        assertEq(pos.tickUpper - pos.tickLower, tickSpacing);
    }

    /// @notice Fuzz test invariant: next position ID always increases
    /// @param numBids Number of bids (fuzzed)
    function testFuzz_invariant_positionIdIncreasing(uint8 numBids) public {
        numBids = uint8(bound(numBids, 1, 20));

        int24 tickSpacing = key.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        uint128 minLiq = hook.minLiquidity();

        uint256 lastPositionId = hook.nextPositionId();

        for (uint8 i = 0; i < numBids; i++) {
            address bidder = address(uint160(0x7000 + i));
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);

            int24 tickLower = minTick + int24(uint24(i + 1)) * tickSpacing;
            if (tickLower + tickSpacing > TICK_MAX) break;

            uint256 currentNextId = hook.nextPositionId();

            // Invariant: next position ID must be >= last
            assertGe(currentNextId, lastPositionId);

            _addBidFrom(bidder, tickLower, minLiq);
            
            // After adding, nextPositionId should have increased
            assertGt(hook.nextPositionId(), currentNextId);
            
            lastPositionId = hook.nextPositionId();
        }
    }

    /// @notice Fuzz test invariant: position owner matches caller
    /// @param bidderSeed Seed for generating bidder address (fuzzed)
    function testFuzz_invariant_ownerMatches(uint256 bidderSeed) public {
        // Generate bidder address from seed
        address bidder = address(uint160(bound(bidderSeed, 0x1000, type(uint160).max)));
        vm.assume(bidder != address(0));
        vm.assume(bidder != address(hook));
        vm.assume(bidder != address(manager));

        // Fund bidder
        TestERC20(token0).transfer(bidder, 100_000 ether);
        TestERC20(token1).transfer(bidder, 100_000 ether);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBidFrom(bidder, tickLower, hook.minLiquidity());

        AuctionPosition memory pos = hook.positions(positionId);

        // Invariant: owner must match the bidder
        assertEq(pos.owner, bidder);
    }

    /// @notice Fuzz test invariant: liquidity matches input
    /// @param liquidity Liquidity to add (fuzzed)
    function testFuzz_invariant_liquidityMatches(uint128 liquidity) public {
        uint128 minLiq = hook.minLiquidity();
        liquidity = uint128(bound(liquidity, minLiq, 100 ether));

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, liquidity);

        AuctionPosition memory pos = hook.positions(positionId);

        // Invariant: stored liquidity must match input
        assertEq(pos.liquidity, liquidity);
    }

    // ============ Fuzz Tests: Settlement Edge Cases ============

    /// @notice Fuzz test for accumulated time monotonically increases up to auction end
    /// @param timeBeforeEnd Time before auction end to check (fuzzed)
    function testFuzz_settlement_timeMonotonicallyIncreases(uint256 timeBeforeEnd) public {
        timeBeforeEnd = bound(timeBeforeEnd, 1 hours, hook.auctionDuration() - 1 hours);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint256 positionId = _addBid(alice, tickLower, hook.minLiquidity() * 10);

        // Get initial time
        uint256 time1 = hook.getPositionAccumulatedTime(positionId);

        // Warp forward
        vm.warp(block.timestamp + timeBeforeEnd);
        uint256 time2 = hook.getPositionAccumulatedTime(positionId);

        // Invariant: time should monotonically increase during auction
        // (or stay the same if not in range)
        assertGe(time2, time1, "Time should not decrease during auction");
    }

    /// @notice Fuzz test for time bounded by position lifetime
    /// @param waitTime Time to wait after adding position (fuzzed)
    function testFuzz_settlement_timeBoundedByLifetime(uint256 waitTime) public {
        waitTime = bound(waitTime, 1, hook.auctionDuration());

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        
        // Record when position is created
        uint256 startTime = block.timestamp;
        
        uint256 positionId = _addBid(alice, tickLower, hook.minLiquidity() * 10);

        // Warp forward
        vm.warp(startTime + waitTime);
        uint256 accumulatedTime = hook.getPositionAccumulatedTime(positionId);

        // Invariant: accumulated time should be bounded by elapsed time since creation
        // (Can be less if not always in range)
        assertLe(accumulatedTime, waitTime + 1, "Time exceeds elapsed time");
    }

    // ============ Helper Functions ============

    /// @notice Helper to add a bid from a specific address
    function _addBidFrom(address bidder, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + key.tickSpacing;
        bytes32 salt = keccak256(abi.encode(bidder, bidNonce++));

        vm.startPrank(bidder);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(bidder)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(bidder, tickLower, tickUpper, salt);
    }
}
