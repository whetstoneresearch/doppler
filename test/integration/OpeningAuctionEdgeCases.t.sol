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
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    OpeningAuctionStatus
} from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionEdgeCaseImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionEdgeCaseDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionEdgeCaseImpl auction = new OpeningAuctionEdgeCaseImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @title Opening Auction Edge Case Tests
/// @notice Tests for boundary conditions, timing edge cases, and cross-contract consistency
contract OpeningAuctionEdgeCasesTest is Test, Deployers {
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

    // Contracts
    OpeningAuctionEdgeCaseDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    // Config
    int24 tickSpacing = 60;
    int24 minAcceptableTick = -34020;
    uint256 auctionDuration = 1 days;
    uint16 incentiveShareBps = 1000; // 10%
    uint128 minLiquidity = 1e15;
    uint256 totalTokens = 100 ether;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionEdgeCaseDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Fund users with large amounts for high liquidity bids
        TestERC20(token0).transfer(alice, 100_000_000 ether);
        TestERC20(token1).transfer(alice, 100_000_000 ether);
        TestERC20(token0).transfer(bob, 100_000_000 ether);
        TestERC20(token1).transfer(bob, 100_000_000 ether);
        TestERC20(token0).transfer(carol, 100_000_000 ether);
        TestERC20(token1).transfer(carol, 100_000_000 ether);
        TestERC20(asset).transfer(creator, totalTokens * 10);
    }

    function getDefaultConfig() internal view returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: auctionDuration,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: incentiveShareBps,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: minLiquidity,
            shareToAuctionBps: 10_000
        });
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

    function mineHookSalt(
        address deployer,
        address caller,
        uint256 auctionTokens,
        OpeningAuctionConfig memory config
    ) internal view returns (bytes32 salt, address hookAddress) {
        bytes memory constructorArgs = abi.encode(
            manager,
            caller,
            auctionTokens,
            config
        );

        (hookAddress, salt) = HookMiner.find(
            deployer,
            getHookFlags(),
            type(OpeningAuctionEdgeCaseImpl).creationCode,
            constructorArgs
        );
    }

    function _createAuction() internal returns (OpeningAuction) {
        return _createAuctionWithConfig(getDefaultConfig());
    }

    function _createAuctionWithConfig(OpeningAuctionConfig memory config) internal returns (OpeningAuction) {
        (bytes32 salt,) = mineHookSalt(address(auctionDeployer), creator, totalTokens, config);

        vm.startPrank(creator);
        OpeningAuction newAuction = auctionDeployer.deploy(
            totalTokens,
            salt,
            abi.encode(config)
        );

        // Transfer tokens to auction
        TestERC20(asset).transfer(address(newAuction), totalTokens);

        // Set isToken0 (asset is token0 if asset < numeraire)
        bool isToken0 = asset == token0;
        newAuction.setIsToken0(isToken0);

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(newAuction))
        });

        // Initialize pool at max tick (highest price, no tokens sold initially)
        int24 maxTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        int24 startingTick = isToken0 ? maxTick : -maxTick;
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        return newAuction;
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + tickSpacing,
                liquidityDelta: int128(liquidity),
                salt: salt
            }),
            abi.encode(user)
        );
        vm.stopPrank();

        positionId = auction.getPositionId(user, tickLower, tickLower + tickSpacing, salt);
    }

    // ============ BOUNDARY TESTS ============

    /// @notice Test settlement when clearingTick lands exactly at minAcceptableTick
    /// @dev For isToken0=true: higher ticks = higher prices. We need bids that create
    ///      enough demand to clear at exactly minAcceptableTick
    function test_SettlementAtExactMinAcceptableTick() public {
        auction = _createAuction();

        // Place large bids at and above minAcceptableTick
        // These create demand that should push clearing tick to minAcceptableTick
        _addBid(alice, minAcceptableTick, 50_000 ether);
        _addBid(bob, minAcceptableTick + tickSpacing, 30_000 ether);

        vm.warp(block.timestamp + auctionDuration + 1);

        int24 estimatedBefore = auction.estimatedClearingTick();
        console2.log("Estimated clearing tick before settlement:", estimatedBefore);

        vm.prank(creator);
        auction.settleAuction();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Auction should be settled");

        int24 actualClearingTick = auction.clearingTick();
        console2.log("Actual clearing tick:", actualClearingTick);

        // Clearing tick should be >= minAcceptableTick
        assertGe(actualClearingTick, minAcceptableTick, "Clearing tick should be >= minAcceptableTick");
    }

    /// @notice Test settlement partial fill when clearing tick would be below minAcceptableTick
    function test_SettlementPartialFillWhenClearingBelowMinAcceptable() public {
        // Use a higher minAcceptableTick so insufficient liquidity causes partial fill
        int24 highMinAcceptableTick = 0; // Require clearing tick >= 0
        
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: auctionDuration,
            minAcceptableTickToken0: highMinAcceptableTick,
            minAcceptableTickToken1: highMinAcceptableTick,
            incentiveShareBps: incentiveShareBps,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: minLiquidity,
            shareToAuctionBps: 10_000
        });

        auction = _createAuctionWithConfig(config);

        // Place a TINY valid bid at exactly minAcceptableTick
        // The bid is valid (tickLower >= minAcceptableTick), but so small it can't absorb all tokens
        // This causes clearing tick to end up much lower than minAcceptableTick
        _addBid(alice, highMinAcceptableTick, minLiquidity); // Minimum liquidity

        vm.warp(block.timestamp + auctionDuration + 1);

        auction.settleAuction();
        uint256 tokensToSell = auction.totalAuctionTokens() - auction.incentiveTokensTotal();
        assertLt(auction.totalTokensSold(), tokensToSell);
        assertEq(auction.clearingTick(), highMinAcceptableTick);
    }

    /// @notice Test bid placement at MIN_TICK boundary (aligned to tick spacing)
    function test_BidAtMinTickBoundary() public {
        // Create auction with very low minAcceptableTick to allow MIN_TICK bids
        int24 veryLowMinTick = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: auctionDuration,
            minAcceptableTickToken0: veryLowMinTick,
            minAcceptableTickToken1: veryLowMinTick,
            incentiveShareBps: incentiveShareBps,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: minLiquidity,
            shareToAuctionBps: 10_000
        });

        auction = _createAuctionWithConfig(config);

        // Place bid at the aligned MIN_TICK
        int24 minTickAligned = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);
        _addBid(alice, minTickAligned, 50_000 ether);

        // Verify position was created
        AuctionPosition memory pos = auction.positions(1);
        assertEq(pos.tickLower, minTickAligned, "Position should be at MIN_TICK aligned");
        assertEq(pos.owner, alice, "Owner should be alice");
    }

    /// @notice Test bid placement at a high tick (well above minAcceptableTick)
    function test_BidNearMaxTickBoundary() public {
        auction = _createAuction();

        // Place bid at a high positive tick (well above minAcceptableTick but safe from overflow)
        // Using a moderate high tick to avoid sqrt price overflow issues
        int24 highTick = tickSpacing * 100; // 6000 with tickSpacing=60

        _addBid(alice, highTick, 50_000 ether);

        // Verify position was created
        AuctionPosition memory pos = auction.positions(1);
        assertEq(pos.tickLower, highTick, "Position should be at high tick");
    }

    // ============ TIMING EDGE CASES ============

    /// @notice Test settlement at exact auction end timestamp
    function test_SettlementAtExactAuctionEndTime() public {
        auction = _createAuction();

        // Place high-tick bids to ensure successful settlement
        _addBid(alice, 0, 50_000 ether);
        _addBid(bob, -tickSpacing, 30_000 ether);

        // Warp to EXACT end time (not +1)
        uint256 auctionEndTime = auction.auctionEndTime();
        vm.warp(auctionEndTime);

        // Settlement should succeed at exact end time
        vm.prank(creator);
        auction.settleAuction();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Should settle at exact end time");
    }

    /// @notice Test that settlement fails one second before auction end
    function test_SettlementFailsBeforeAuctionEnd() public {
        auction = _createAuction();

        _addBid(alice, 0, 50_000 ether);

        // Warp to 1 second before end
        uint256 auctionEndTime = auction.auctionEndTime();
        vm.warp(auctionEndTime - 1);

        // Settlement should fail
        vm.prank(creator);
        vm.expectRevert(); // AuctionNotEnded
        auction.settleAuction();
    }

    /// @notice Test bid placement in the same block as auction start
    function test_BidInSameBlockAsStart() public {
        auction = _createAuction();

        // Immediately after initialization (same block), place a bid
        _addBid(alice, 0, 50_000 ether);

        // Verify bid was accepted
        AuctionPosition memory pos = auction.positions(1);
        assertEq(pos.owner, alice, "Bid should be accepted in same block as start");
    }

    /// @notice Test settlement with bid placed just before auction end
    function test_SettlementWithLastMinuteBid() public {
        auction = _createAuction();

        _addBid(alice, 0, 50_000 ether);

        // Warp to just before auction end
        vm.warp(auction.auctionEndTime() - 1);

        // Place another bid in this block (should still work)
        _addBid(bob, -tickSpacing, 30_000 ether);

        // Now warp to exact auction end
        vm.warp(auction.auctionEndTime());

        // Settle
        vm.prank(creator);
        auction.settleAuction();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Should settle with last-minute bid included");
    }

    // ============ ESTIMATED CLEARING TICK ACCURACY ============

    /// @notice Test that estimatedClearingTick is reasonable after single bid
    function test_EstimatedClearingTickAccuracy_SingleBidder() public {
        auction = _createAuction();

        _addBid(alice, 0, 50_000 ether);

        vm.warp(block.timestamp + auctionDuration + 1);

        int24 estimatedBefore = auction.estimatedClearingTick();

        vm.prank(creator);
        auction.settleAuction();

        int24 actualClearingTick = auction.clearingTick();

        console2.log("Estimated before settlement:", estimatedBefore);
        console2.log("Actual clearing tick:", actualClearingTick);

        // The estimated clearing tick should be close to actual
        int24 diff = estimatedBefore > actualClearingTick
            ? estimatedBefore - actualClearingTick
            : actualClearingTick - estimatedBefore;

        assertLe(diff, tickSpacing, "Estimated should be within 1 tick spacing of actual");
    }

    /// @notice Test estimatedClearingTick accuracy with multiple bidders at different ticks
    function test_EstimatedClearingTickAccuracy_MultipleBidders() public {
        auction = _createAuction();

        // Place bids at various price levels (higher ticks = higher prices)
        _addBid(alice, 0, 40_000 ether);
        _addBid(bob, -tickSpacing, 30_000 ether);
        _addBid(carol, -tickSpacing * 2, 20_000 ether);

        vm.warp(block.timestamp + auctionDuration + 1);

        int24 estimatedBefore = auction.estimatedClearingTick();

        vm.prank(creator);
        auction.settleAuction();

        int24 actualClearingTick = auction.clearingTick();

        console2.log("Estimated (multi-bidder):", estimatedBefore);
        console2.log("Actual (multi-bidder):", actualClearingTick);

        // Check estimation accuracy
        int24 diff = estimatedBefore > actualClearingTick
            ? estimatedBefore - actualClearingTick
            : actualClearingTick - estimatedBefore;

        assertLe(diff, tickSpacing, "Estimated should be within 1 tick spacing with multiple bidders");
    }

    // ============ POSITION INCREASE SCENARIOS ============

    /// @notice Test that adding liquidity to an existing tick creates a NEW position
    function test_PositionIncrease_CreatesNewPosition() public {
        auction = _createAuction();

        // First bid from alice
        uint256 firstPositionId = _addBid(alice, 0, 25_000 ether);

        AuctionPosition memory pos1 = auction.positions(firstPositionId);
        assertEq(pos1.liquidity, 25_000 ether, "First position should have 25k ether liquidity");

        // Second bid from alice at SAME tick - should create NEW position
        uint256 secondPositionId = _addBid(alice, 0, 15_000 ether);

        // Verify two separate positions exist
        AuctionPosition memory pos2 = auction.positions(secondPositionId);
        assertEq(pos2.liquidity, 15_000 ether, "Second position should have 15k ether liquidity");
        assertEq(pos2.owner, alice, "Second position should be owned by alice");

        // First position should be unchanged
        AuctionPosition memory pos1After = auction.positions(firstPositionId);
        assertEq(pos1After.liquidity, 25_000 ether, "First position liquidity should be unchanged");

        // Verify position IDs are different
        assertEq(secondPositionId, firstPositionId + 1, "Should have incremented position ID");
    }

    /// @notice Test multiple positions from same user at different ticks
    function test_MultiplePositions_DifferentTicks() public {
        auction = _createAuction();

        // Alice places bids at three different ticks
        _addBid(alice, 0, 30_000 ether);
        _addBid(alice, -tickSpacing, 20_000 ether);
        _addBid(alice, -tickSpacing * 2, 10_000 ether);

        // Verify all three positions exist and are separate
        for (uint256 i = 1; i <= 3; i++) {
            AuctionPosition memory pos = auction.positions(i);
            assertEq(pos.owner, alice, "All positions should be owned by alice");
        }

        assertEq(auction.nextPositionId(), 4, "Should have 3 positions created");
    }

    // ============ CROSS-CONTRACT STATE CONSISTENCY ============

    /// @notice Test that phase transitions are consistent
    function test_PhaseTransitionConsistency() public {
        auction = _createAuction();

        // Check initial phase after initialization
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active), "Should start Active");

        // Place bid
        _addBid(alice, 0, 50_000 ether);

        // Still Active
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active), "Should still be Active after bid");

        // Warp past end
        vm.warp(block.timestamp + auctionDuration + 1);

        // Still Active (just ended, not settled)
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Active), "Should be Active before settlement");

        // Settle
        vm.prank(creator);
        auction.settleAuction();

        // Now Settled
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Should be Settled after settlement");
    }

    /// @notice Test that state variables are consistent after settlement
    function test_StateConsistencyAfterSettlement() public {
        auction = _createAuction();

        _addBid(alice, 0, 50_000 ether);
        _addBid(bob, -tickSpacing, 30_000 ether);

        vm.warp(block.timestamp + auctionDuration + 1);

        vm.prank(creator);
        auction.settleAuction();

        // Verify state consistency
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Phase should be Settled");
        assertGt(auction.totalTokensSold(), 0, "Should have sold some tokens");
        assertGt(auction.totalProceeds(), 0, "Should have proceeds");
        assertGe(auction.clearingTick(), minAcceptableTick, "Clearing tick should be >= minAcceptableTick");

        // Verify cached incentive values are set
        uint256 cachedTime = auction.cachedTotalWeightedTimeX128();
        console2.log("Cached total weighted time:", cachedTime);

        // If there was time in range, cached should be > 0
        if (cachedTime > 0) {
            // Incentives should be claimable
            uint256 aliceIncentives = auction.calculateIncentives(1);
            console2.log("Alice incentives:", aliceIncentives);
        }
    }

    /// @notice Test that position state is preserved correctly through settlement
    function test_PositionStatePreservationThroughSettlement() public {
        auction = _createAuction();

        _addBid(alice, 0, 50_000 ether);

        AuctionPosition memory posBefore = auction.positions(1);

        vm.warp(block.timestamp + auctionDuration + 1);

        vm.prank(creator);
        auction.settleAuction();

        AuctionPosition memory posAfter = auction.positions(1);

        // Core position data should be unchanged
        assertEq(posAfter.owner, posBefore.owner, "Owner should be unchanged");
        assertEq(posAfter.tickLower, posBefore.tickLower, "tickLower should be unchanged");
        assertEq(posAfter.tickUpper, posBefore.tickUpper, "tickUpper should be unchanged");
        assertEq(posAfter.liquidity, posBefore.liquidity, "liquidity should be unchanged");
    }

    // ============ LIQUIDITY AT TICK TRACKING ============

    /// @notice Test that liquidityAtTick is accurately tracked
    function test_LiquidityAtTickTracking() public {
        auction = _createAuction();

        // Add multiple bids at same tick
        _addBid(alice, 0, 30_000 ether);
        _addBid(bob, 0, 20_000 ether);

        // Check liquidity at tick
        uint128 liquidityAtZero = auction.liquidityAtTick(0);
        assertEq(liquidityAtZero, 50_000 ether, "Liquidity should be sum of both bids");

        // Add bid at different tick
        _addBid(carol, -tickSpacing, 15_000 ether);

        uint128 liquidityAtNextTick = auction.liquidityAtTick(-tickSpacing);
        assertEq(liquidityAtNextTick, 15_000 ether, "Liquidity at next tick should be carol's bid");

        // Original tick liquidity unchanged
        assertEq(auction.liquidityAtTick(0), 50_000 ether, "Original tick liquidity unchanged");
    }

    /// @notice Test that bids at various tick levels all get tracked
    function test_BidsAtVariousTicks() public {
        auction = _createAuction();

        // Place bids at various ticks - verify each is tracked via liquidityAtTick
        _addBid(alice, 0, 40_000 ether);
        assertEq(auction.liquidityAtTick(0), 40_000 ether, "First bid tracked");

        _addBid(bob, -tickSpacing * 5, 30_000 ether);
        assertEq(auction.liquidityAtTick(-tickSpacing * 5), 30_000 ether, "Lower bid tracked");

        _addBid(carol, -tickSpacing * 10, 20_000 ether);
        assertEq(auction.liquidityAtTick(-tickSpacing * 10), 20_000 ether, "Even lower bid tracked");

        // Verify total positions created
        assertEq(auction.nextPositionId(), 4, "Should have 3 positions");
    }
}
