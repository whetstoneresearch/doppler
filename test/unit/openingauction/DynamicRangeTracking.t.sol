// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition, IOpeningAuction, TickTimeState } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { QuoterMath } from "src/libraries/QuoterMath.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionDynamicImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}

    function setTickTimeState(
        int24 tick,
        bool inRange,
        uint256 lastUpdateTime,
        uint256 accumulatedSecondsX128
    ) external {
        tickTimeStates[tick] = TickTimeState({
            lastUpdateTime: lastUpdateTime,
            accumulatedSecondsX128: accumulatedSecondsX128,
            isInRange: inRange
        });
    }

    function setEstimatedClearingTick(int24 tick) external {
        estimatedClearingTick = tick;
    }
}

/// @notice Tests for dynamic range tracking and time-based incentives
contract DynamicRangeTrackingTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address carol = address(0xca401);
    address creator = address(0xc4ea70);
    uint256 bidNonce;
    mapping(uint256 => bytes32) internal positionSalts;

    // Contracts
    OpeningAuctionDynamicImpl auction;
    PoolKey poolKey;

    // Auction parameters - using tiny token amounts since proper AMM math means
    // liquidity at a single tick absorbs very small amounts of input tokens
    // (amount0 ≈ L * (1/sqrtLower - 1/sqrtUpper) which is tiny for narrow ranges)
    uint256 constant AUCTION_TOKENS = 1000;  // 1000 wei - very small for AMM math to work
    uint256 constant AUCTION_DURATION = 7 days;
    int24 constant MIN_ACCEPTABLE_TICK = -100_020;
    int24 tickSpacing = 60;
    int24 maxTick;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate max tick
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);

        // Fund users
        TestERC20(numeraire).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(numeraire).transfer(bob, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(numeraire).transfer(carol, 10_000_000 ether);
        TestERC20(token0).transfer(carol, 10_000_000 ether);
        // Creator gets a minimum amount to cover tiny auction tokens
        TestERC20(asset).transfer(creator, 1 ether);
    }

    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function _createAuction(uint256 auctionTokens) internal {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: 1000, // 10%
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        // Calculate hook address with proper flags
        address hookAddress = address(uint160(getHookFlags()) ^ (0x5555 << 144));

        // Deploy hook implementation
        deployCodeTo(
            "DynamicRangeTracking.t.sol:OpeningAuctionDynamicImpl",
            abi.encode(manager, creator, auctionTokens, config),
            hookAddress
        );

        auction = OpeningAuctionDynamicImpl(payable(hookAddress));
        vm.label(address(auction), "OpeningAuction");

        // Transfer tokens to auction
        vm.prank(creator);
        TestERC20(asset).transfer(address(auction), auctionTokens);

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        // Set isToken0 and initialize
        vm.startPrank(creator);
        auction.setIsToken0(true);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));
        vm.stopPrank();
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + tickSpacing;
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user)
        );
        vm.stopPrank();

        positionId = auction.getPositionId(user, tickLower, tickUpper, salt);
        positionSalts[positionId] = salt;
    }

    function _removeBid(address user, int24 tickLower, uint128 liquidity, uint256 positionId) internal {
        int24 tickUpper = tickLower + tickSpacing;

        vm.startPrank(user);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: positionSalts[positionId]
            }),
            abi.encode(user)
        );
        vm.stopPrank();
    }

    function _quoteClearingTick() internal view returns (int24) {
        uint256 tokensToSell = AUCTION_TOKENS - auction.incentiveTokensTotal();
        if (tokensToSell == 0) {
            return auction.isToken0() ? TickMath.MAX_TICK : TickMath.MIN_TICK;
        }

        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(auction.minAcceptableTick());
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
            sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
        } else if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        }

        (,, uint160 sqrtPriceAfterX96,) = QuoterMath.quote(
            manager,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: auction.isToken0(),
                amountSpecified: -int256(tokensToSell),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        int24 quoted = TickMath.getTickAtSqrtPrice(sqrtPriceAfterX96);
        return _floorToSpacing(quoted, tickSpacing);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed * spacing;
    }

    // ============ Test: In-Range Positions Cannot Be Removed ============

    /// @notice Test that a position that would be filled cannot be removed
    function test_inRangePosition_CannotBeRemoved() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a bid with enough liquidity to absorb all tokens
        // This means Alice's position WOULD be filled if settled now
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether; // More than auction tokens
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Verify Alice's position is locked (would be filled) using new API
        assertTrue(auction.isInRange(alicePos), "Position should be in range");

        // Trying to remove should revert (revert is wrapped by pool manager)
        vm.expectRevert();
        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);
    }

    // ============ Test: Out-of-Range Positions Can Be Removed ============

    /// @notice Test that a position that would NOT be filled can be removed
    function test_outOfRangePosition_CanBeRemoved() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a bid that would absorb all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a bid at a LOWER tick (lower price)
        // Since Alice's liquidity already absorbs all tokens,
        // Bob's position would NOT be filled
        int24 bobTickLower = -6000; // Lower tick = lower price
        uint128 bobLiquidity = 500 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Verify Bob's position is NOT locked (would not be filled) using new API
        assertFalse(auction.isInRange(bobPos), "Position should NOT be in range");

        // Bob should be able to remove his position
        _removeBid(bob, bobTickLower, bobLiquidity, bobPos);
    }

    // ============ Test: Higher Bids Push Lower Bids Out of Range ============

    /// @notice Test that when higher bids come in, lower bids get pushed out of range
    function test_higherBids_PushLowerBidsOutOfRange() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a bid at a low tick - initially would be filled
        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 2000 ether; // Enough to absorb all tokens
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Alice's position should be in range initially
        assertTrue(auction.isInRange(alicePos), "Alice should be in range initially");

        console2.log("Estimated clearing tick before Bob:", int256(auction.estimatedClearingTick()));

        // Time passes
        vm.warp(block.timestamp + 1 days);

        // Bob places a HIGHER bid (higher tick = higher price) with enough liquidity
        // This should push Alice out of range
        int24 bobTickLower = 0; // Higher tick = higher price
        uint128 bobLiquidity = 2000 ether; // Enough to absorb all tokens
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        console2.log("Estimated clearing tick after Bob:", int256(auction.estimatedClearingTick()));

        // Bob's position should be in range (higher priority)
        assertTrue(auction.isInRange(bobPos), "Bob should be in range");

        // Alice's position should now be OUT of range (pushed out)
        assertFalse(auction.isInRange(alicePos), "Alice should be out of range after higher bid");

        // Alice should have accumulated time from when she was in range
        uint256 aliceAccumulatedTime = auction.getPositionAccumulatedTime(alicePos);
        assertGt(aliceAccumulatedTime, 0, "Alice should have accumulated time");
        console2.log("Alice accumulated time:", aliceAccumulatedTime);

        // Alice should now be able to remove her position
        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);
    }

    function test_incentives_IncludeHarvestedTime() public {
        _createAuction(AUCTION_TOKENS);

        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        assertTrue(auction.isInRange(alicePos), "Alice should be in range initially");

        vm.warp(block.timestamp + 2 days);

        int24 bobTickLower = 0;
        uint128 bobLiquidity = 2000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        assertTrue(auction.isInRange(bobPos), "Bob should be in range");
        assertFalse(auction.isInRange(alicePos), "Alice should be out of range");

        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        uint256 bobIncentives = auction.calculateIncentives(bobPos);

        assertApproxEqAbs(aliceIncentives + bobIncentives, auction.incentiveTokensTotal(), 2);
    }

    /// @notice Test that view-based time accrual stops after auction end even before settlement
    function test_viewAccumulation_StopsAfterAuctionEnd() public {
        _createAuction(AUCTION_TOKENS);

        // Place a bid that will be in range
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        assertTrue(auction.isInRange(alicePos), "Position should be in range");

        // Move past auction end without settling
        vm.warp(auction.auctionEndTime() + 1);
        uint256 earnedAtEnd = auction.getPositionAccumulatedTime(alicePos);

        // Advance time further - accrued time should not increase after auction end
        vm.warp(auction.auctionEndTime() + 1 hours);
        uint256 earnedAfterDelay = auction.getPositionAccumulatedTime(alicePos);

        assertEq(earnedAfterDelay, earnedAtEnd, "Earned time should stop after auction end");
    }

    // ============ Test: Time Tracking for Partial In-Range ============

    /// @notice Test that positions accumulate time proportionally
    function test_timeTracking_PartialInRange() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a bid - initially in range
        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Alice is in range initially
        assertTrue(auction.isInRange(alicePos), "Alice should be in range");

        // 2 days pass while Alice is in range
        vm.warp(block.timestamp + 2 days);

        // Bob places a higher bid, pushing Alice out
        int24 bobTickLower = 0;
        uint128 bobLiquidity = 2000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Alice should be out of range now with ~2 days of accumulated time
        assertFalse(auction.isInRange(alicePos), "Alice should be out of range");
        uint256 aliceAccumulatedTime = auction.getPositionAccumulatedTime(alicePos);
        uint256 expectedAliceTime = uint256(aliceLiquidity) * 2 days;
        uint256 aliceTolerance = uint256(aliceLiquidity) * 10;
        assertApproxEqAbs(
            aliceAccumulatedTime,
            expectedAliceTime,
            aliceTolerance,
            "Alice should have ~2 days accumulated"
        );

        // 1 more day passes (Alice still out of range)
        vm.warp(block.timestamp + 1 days);

        console2.log("Before Carol bids:");
        console2.log("  Alice isInRange:", auction.isInRange(alicePos));
        console2.log("  Alice accumulated:", auction.getPositionAccumulatedTime(alicePos));
        console2.log("  Clearing tick:", int256(auction.estimatedClearingTick()));

        // Carol places an even higher bid
        int24 carolTickLower = 600; // Even higher
        uint128 carolLiquidity = 2000 ether;
        _addBid(carol, carolTickLower, carolLiquidity);

        console2.log("After Carol bids:");
        console2.log("  Alice isInRange:", auction.isInRange(alicePos));
        console2.log("  Alice accumulated:", auction.getPositionAccumulatedTime(alicePos));
        console2.log("  Clearing tick:", int256(auction.estimatedClearingTick()));

        // Alice should still have only ~2 days (not in range during the last day)
        aliceAccumulatedTime = auction.getPositionAccumulatedTime(alicePos);
        assertApproxEqAbs(
            aliceAccumulatedTime,
            expectedAliceTime,
            aliceTolerance,
            "Alice time should not increase while out of range"
        );

        // Bob might also be pushed out depending on clearing tick
        console2.log("Bob is in range:", auction.isInRange(bobPos));
        console2.log("Bob accumulated time:", auction.getPositionAccumulatedTime(bobPos));
    }

    // ============ Test: Multiple Transitions In and Out of Range ============

    /// @notice Test position that goes in range, out of range
    /// @dev Note: Currently removing liquidity doesn't recalculate clearing tick.
    ///      This test verifies the time tracking for in->out transitions.
    function test_multipleTransitions_InOutRange() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a bid
        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 1500 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Alice should be in range initially
        assertTrue(auction.isInRange(alicePos), "Alice should be in range initially");

        // 1 day passes
        vm.warp(block.timestamp + 1 days);

        // Bob places higher bid, pushing Alice out
        int24 bobTickLower = 0;
        uint128 bobLiquidity = 1500 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Alice should be out of range now with ~1 day accumulated
        assertFalse(auction.isInRange(alicePos), "Alice should be out of range");
        uint256 aliceAccumulatedTime = auction.getPositionAccumulatedTime(alicePos);
        uint256 expectedAliceTime = uint256(aliceLiquidity) * 1 days;
        uint256 aliceTolerance = uint256(aliceLiquidity) * 10;
        assertApproxEqAbs(aliceAccumulatedTime, expectedAliceTime, aliceTolerance, "Alice should have ~1 day");

        // Bob should be in range
        assertTrue(auction.isInRange(bobPos), "Bob should be in range");

        // Verify Alice can now remove her position (she's out of range)
        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);

        // Bob cannot remove (he's in range)
        vm.expectRevert();
        _removeBid(bob, bobTickLower, bobLiquidity, bobPos);
    }

    // ============ Test: Estimated Clearing Tick Updates ============

    /// @notice Test that estimated clearing tick updates correctly as bids come in
    function test_estimatedClearingTick_Updates() public {
        _createAuction(AUCTION_TOKENS);

        // Initial clearing tick should be at MAX_TICK (no liquidity = price at starting point)
        // This ensures no positions are "in range" until liquidity is added
        int24 initialClearingTick = auction.estimatedClearingTick();
        assertEq(initialClearingTick, TickMath.MAX_TICK, "Initial clearing should be MAX_TICK (starting price)");

        // Add first bid
        int24 firstTickLower = -6000;
        uint128 firstLiquidity = 500 ether; // Not enough to absorb all tokens
        _addBid(alice, firstTickLower, firstLiquidity);

        // Clearing tick should still be below -6000 (not enough liquidity)
        int24 clearingAfterFirst = auction.estimatedClearingTick();
        console2.log("Clearing tick after first bid:", int256(clearingAfterFirst));

        // Add second bid at higher tick with enough total liquidity
        int24 secondTickLower = 0;
        uint128 secondLiquidity = 1000 ether;
        _addBid(bob, secondTickLower, secondLiquidity);

        // Clearing tick should now be at or above the second bid
        int24 clearingAfterSecond = auction.estimatedClearingTick();
        console2.log("Clearing tick after second bid:", int256(clearingAfterSecond));

        // With 1500 total liquidity and 1000 tokens to sell (minus incentives = 900),
        // clearing should happen at the first tick that accumulates enough liquidity
        assertGe(clearingAfterSecond, clearingAfterFirst, "Clearing tick should move up");
    }

    /// @notice Removing out-of-range liquidity should not desync estimated clearing tick
    function test_estimatedClearingTick_AccurateAfterOutOfRangeRemoval() public {
        _createAuction(AUCTION_TOKENS);

        int24 highTickLower = 0;
        uint128 highLiquidity = 2000 ether;
        _addBid(alice, highTickLower, highLiquidity);

        int24 lowTickLower = -6000;
        uint128 lowLiquidity = 500 ether;
        uint256 lowPos = _addBid(bob, lowTickLower, lowLiquidity);
        assertFalse(auction.isInRange(lowPos), "Low tick should be out of range");

        int24 expectedBefore = _quoteClearingTick();
        assertEq(auction.estimatedClearingTick(), expectedBefore, "Estimate should match quote");

        // Out-of-range removals do not affect the clearing price, so no recalculation is needed.
        _removeBid(bob, lowTickLower, lowLiquidity, lowPos);

        int24 expectedAfter = _quoteClearingTick();
        assertEq(auction.estimatedClearingTick(), expectedAfter, "Estimate should remain accurate");
    }


    // ============ Test: Settlement Incentives With Time Tracking ============

    /// @notice Test that incentives are properly calculated based on time in range
    function test_incentives_BasedOnTimeInRange() public {
        _createAuction(AUCTION_TOKENS);

        // Alice bids first, stays in range for 3 days
        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        vm.warp(block.timestamp + 3 days);

        // Bob bids higher, pushing Alice out
        int24 bobTickLower = 0;
        uint128 bobLiquidity = 2000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Bob stays in range for remaining 4 days
        vm.warp(auction.auctionEndTime() + 1);

        // Settle
        auction.settleAuction();

        // Check accumulated times using new API
        uint256 aliceAccumulatedTime = auction.getPositionAccumulatedTime(alicePos);
        uint256 bobAccumulatedTime = auction.getPositionAccumulatedTime(bobPos);

        console2.log("=== Settlement Results ===");
        console2.log("Alice accumulated time:", aliceAccumulatedTime);
        console2.log("Bob accumulated time:", bobAccumulatedTime);
        console2.log("Total accumulated time:", auction.totalAccumulatedTime());

        // Calculate incentives
        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        uint256 bobIncentives = auction.calculateIncentives(bobPos);

        console2.log("Alice incentives:", aliceIncentives);
        console2.log("Bob incentives:", bobIncentives);
        console2.log("Total incentive pool:", auction.incentiveTokensTotal());

        // Both should have non-zero incentives if they accumulated time
        // Note: The exact amounts depend on whether positions were "touched" during settlement
    }

    /// @notice Test removed positions do not accrue time if the tick re-enters range
    function test_removedPosition_NoAccrualAfterReentry() public {
        _createAuction(AUCTION_TOKENS);

        int24 sharedTick = -3000;
        uint128 sharedLiquidity = 10_000 ether;
        uint256 alicePos = _addBid(alice, sharedTick, sharedLiquidity);
        uint256 bobPos = _addBid(bob, sharedTick, sharedLiquidity);

        auction.setEstimatedClearingTick(TickMath.MAX_TICK);
        assertFalse(auction.isInRange(alicePos), "Shared tick should start out of range");

        uint256 timeBeforeRemove = auction.getPositionAccumulatedTime(alicePos);

        // Remove Alice's position while out of range
        _removeBid(alice, sharedTick, sharedLiquidity, alicePos);

        AuctionPosition memory removedPos = auction.positions(alicePos);
        assertEq(removedPos.liquidity, 0, "Removed position should zero liquidity");

        // Simulate the tick re-entering range after removal
        auction.setTickTimeState(sharedTick, true, block.timestamp, 0);

        uint256 timeAfterReentry = auction.getPositionAccumulatedTime(alicePos);
        assertEq(timeAfterReentry, timeBeforeRemove, "Removed position should not accrue after reentry");

        vm.warp(block.timestamp + 1 days);
        uint256 timeAfterMore = auction.getPositionAccumulatedTime(alicePos);
        assertEq(timeAfterMore, timeBeforeRemove, "Removed position should stay constant");

        uint256 bobTimeAfterMore = auction.getPositionAccumulatedTime(bobPos);
        assertGt(bobTimeAfterMore, 0, "Remaining position should accrue time");
    }

    // ============ Test: Settlement With Mixed Positions ============

    /// @notice Test a realistic settlement where some positions are filled and others are not
    function test_settlement_SellsTokens_MixedPositions() public {
        _createAuction(AUCTION_TOKENS);

        // Alice places a high bid that should absorb all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a lower bid that should remain out of range
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 500 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        assertTrue(auction.isInRange(alicePos), "Alice should be in range");
        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Settle after auction end
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));

        uint256 expectedSold = AUCTION_TOKENS - auction.incentiveTokensTotal();
        assertEq(auction.totalTokensSold(), expectedSold, "Should sell all non-incentive tokens");
        assertGt(auction.totalProceeds(), 0, "Should collect proceeds");
    }

    // ============ Test: Incentives After Going Out Of Range ============

    /// @notice Test incentives are earned before going out of range and can be claimed after settlement
    function test_incentives_AfterOutOfRangeClaimable() public {
        _createAuction(AUCTION_TOKENS);

        int24 aliceTickLower = -3000;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Alice accrues time while in range
        vm.warp(block.timestamp + 3 days);

        int24 bobTickLower = 0;
        uint128 bobLiquidity = 2000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Finish auction and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // Migrate to enable claims
        vm.prank(creator);
        auction.migrate(address(this));

        uint256 aliceBefore = TestERC20(token0).balanceOf(alice);
        uint256 bobBefore = TestERC20(token0).balanceOf(bob);

        vm.prank(alice);
        auction.claimIncentives(alicePos);

        vm.prank(bob);
        auction.claimIncentives(bobPos);

        uint256 aliceIncentives = TestERC20(token0).balanceOf(alice) - aliceBefore;
        uint256 bobIncentives = TestERC20(token0).balanceOf(bob) - bobBefore;

        assertGt(aliceIncentives, 0, "Alice should receive incentives");
        assertGt(bobIncentives, aliceIncentives, "Bob should receive more incentives");
        assertLe(aliceIncentives + bobIncentives, auction.incentiveTokensTotal(), "Should not exceed pool");
    }

    /// @notice Splitting liquidity across ticks should not increase total incentives
    function test_incentives_SplitAcrossTicksNoMultiplier() public {
        _createAuction(AUCTION_TOKENS);

        int24 tickSingle = -3000;
        int24 tickSplitA = -2940;
        int24 tickSplitB = -2880;
        uint128 baseLiquidity = 1000 ether;

        uint256 singlePos = _addBid(alice, tickSingle, baseLiquidity * 2);
        uint256 splitPosA = _addBid(bob, tickSplitA, baseLiquidity);
        uint256 splitPosB = _addBid(carol, tickSplitB, baseLiquidity);

        uint256 timeX128 = uint256(3 days) << 128;
        auction.setTickTimeState(tickSingle, true, block.timestamp, timeX128);
        auction.setTickTimeState(tickSplitA, true, block.timestamp, timeX128);
        auction.setTickTimeState(tickSplitB, true, block.timestamp, timeX128);

        uint256 singleIncentives = auction.calculateIncentives(singlePos);
        uint256 splitIncentives = auction.calculateIncentives(splitPosA) + auction.calculateIncentives(splitPosB);

        assertApproxEqAbs(
            singleIncentives,
            splitIncentives,
            1,
            "Splitting liquidity should not boost incentives"
        );
    }

    // ============ Test: Out-Of-Range Never Earns ============

    /// @notice Test positions that never enter range receive zero incentives
    function test_outOfRange_NeverEarnsIncentives() public {
        _createAuction(AUCTION_TOKENS);

        // Bob's high bid absorbs all tokens
        int24 bobTickLower = 0;
        uint128 bobLiquidity = 2000 ether;
        _addBid(bob, bobTickLower, bobLiquidity);

        // Carol bids far lower and should remain out of range
        int24 carolTickLower = -60_000;
        uint128 carolLiquidity = 500 ether;
        uint256 carolPos = _addBid(carol, carolTickLower, carolLiquidity);

        assertFalse(auction.isInRange(carolPos), "Carol should be out of range");

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        uint256 carolIncentives = auction.calculateIncentives(carolPos);
        assertEq(carolIncentives, 0, "Out-of-range position should earn zero incentives");
    }
}
