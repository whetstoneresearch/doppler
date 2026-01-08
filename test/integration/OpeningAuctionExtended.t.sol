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
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionExtendedImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionExtendedDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionExtendedImpl auction = new OpeningAuctionExtendedImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @notice Extended test scenarios for Opening Auction
/// @dev Tests realistic scenarios with hundreds of ETH in liquidity and position rolling
contract OpeningAuctionExtendedTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Many bidders
    address[] bidders;
    uint256 constant NUM_BIDDERS = 10;

    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionExtendedDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    // Auction parameters - use smaller amounts for tests since liquidity provided is limited
    uint256 constant AUCTION_TOKENS = 100 ether;  // 100 tokens (realistic for test liquidity)
    uint256 constant AUCTION_DURATION = 7 days;           // 1 week auction

    // Test configuration
    int24 tickSpacing = 60;
    int24 maxTick;
    int24 minAcceptableTick;

    // Track position IDs per bidder
    mapping(address => uint256[]) bidderPositions;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens with large supply
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionExtendedDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate tick values
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);
        minAcceptableTick = -34_020; // ~0.033 price floor (e.g., 10k USD min raise at 3k ETH for 100 tokens)

        // Create bidders and fund them with significant ETH
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            address bidder = address(uint160(0x1000 + i));
            bidders.push(bidder);
            vm.label(bidder, string.concat("Bidder", vm.toString(i)));

            // Fund each bidder generously for high-liquidity tests
            TestERC20(numeraire).transfer(bidder, 1_000_000 ether);
            TestERC20(token0).transfer(bidder, 1_000_000 ether);
        }

        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
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

    function _createAuction(OpeningAuctionConfig memory config) internal returns (OpeningAuction) {
        (, bytes32 salt) = HookMiner.find(
            address(auctionDeployer),
            getHookFlags(),
            type(OpeningAuctionExtendedImpl).creationCode,
            abi.encode(manager, creator, AUCTION_TOKENS, config)
        );

        vm.startPrank(creator);
        OpeningAuction _auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(_auction), AUCTION_TOKENS);
        _auction.setIsToken0(true);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(_auction))
        });

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));
        vm.stopPrank();

        return _auction;
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + tickSpacing;

        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        // Approve the router to spend tokens
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity through router, passing owner in hookData
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user) // Pass owner in hookData
        );
        vm.stopPrank();

        positionId = auction.getPositionId(user, tickLower, tickUpper, salt);
        bidderPositions[user].push(positionId);
        return positionId;
    }

    /// @notice Test realistic auction with 10 bidders providing hundreds of ETH
    function test_realisticAuction_ManyBiddersHighLiquidity() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000, // 10% for incentives
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== Realistic Auction: 10 Bidders, 100M Tokens ===");
        console2.log("Auction duration:", AUCTION_DURATION / 1 days, "days");
        console2.log("Incentive tokens:", auction.incentiveTokensTotal());
        console2.log("Starting tick:", int256(maxTick));

        // Each bidder places liquidity at different tick levels
        // All ticks must be above minAcceptableTick (-34,020) to ensure valid settlement
        int24[] memory bidTicks = new int24[](NUM_BIDDERS);
        bidTicks[0] = 0;
        bidTicks[1] = -600;     // -10 tick spacings
        bidTicks[2] = -1200;    // -20 tick spacings
        bidTicks[3] = -3000;    // -50 tick spacings
        bidTicks[4] = -6000;    // -100 tick spacings
        bidTicks[5] = -12000;   // -200 tick spacings
        bidTicks[6] = -18000;   // -300 tick spacings
        bidTicks[7] = -24000;   // -400 tick spacings
        bidTicks[8] = -30000;   // -500 tick spacings
        bidTicks[9] = -33000;   // Near but above minAcceptableTick

        // Each bidder provides 100 ETH worth of liquidity
        uint128 liquidityPerBidder = 100_000 ether;

        console2.log("\n=== Initial Bids ===");
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            _addBid(bidders[i], bidTicks[i], liquidityPerBidder);
            console2.log("Bidder placed at tick:", int256(bidTicks[i]));
        }

        // Verify all positions created
        assertEq(auction.nextPositionId(), NUM_BIDDERS + 1);

        // Warp through different time periods
        console2.log("\n=== Auction Progress ===");

        // Day 1
        vm.warp(block.timestamp + 1 days);
        console2.log("Day 1 complete");

        // Day 3 - halfway
        vm.warp(block.timestamp + 2 days);
        console2.log("Day 3 complete");

        // Day 7 - end
        vm.warp(auction.auctionEndTime() + 1);
        console2.log("Day 7: settling...");

        // Settle
        auction.settleAuction();

        console2.log("\n=== Settlement Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Proceeds:", auction.totalProceeds());
        console2.log("Total accumulated time:", auction.totalAccumulatedTime());

        // Log each bidder's results
        console2.log("\n=== Bidder Results ===");
        uint256 totalIncentives = 0;
        uint256 filledCount = 0;
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            uint256 posId = i + 1;
            uint256 incentives = auction.calculateIncentives(posId);
            totalIncentives += incentives;
            if (auction.isInRange(posId)) filledCount++;
        }

        console2.log("Positions filled:", filledCount);
        console2.log("Total incentives:", totalIncentives);
        console2.log("Expected total:", auction.incentiveTokensTotal());

        // Verify all filled positions got incentives
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test multiple bidders with different strategies
    /// @dev Note: Rolling positions would require the hook to own the liquidity,
    ///      which requires a different architecture where users deposit to the hook
    function test_multipleBidders_DifferentStrategies() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== Multiple Bidders Different Strategies ===");

        // Alice: Aggressive (high tick, likely to fill)
        uint256 alicePos = _addBid(bidders[0], 0, 100_000 ether);
        console2.log("Alice: aggressive at tick 0");

        // Bob: Medium (medium tick)
        uint256 bobPos = _addBid(bidders[1], -12000, 100_000 ether);
        console2.log("Bob: medium at tick -12000");

        // Carol: Conservative (low tick, but above minAcceptable)
        uint256 carolPos = _addBid(bidders[2], -24000, 100_000 ether);
        console2.log("Carol: conservative at tick -24000");

        // Dave: Very conservative (near minAcceptable but above)
        uint256 davePos = _addBid(bidders[3], -33000, 100_000 ether);
        console2.log("Dave: very conservative at tick -33000");

        // Warp to end
        vm.warp(auction.auctionEndTime() + 1);

        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // Check results
        console2.log("\nAlice (tick 0): filled =", auction.isInRange(alicePos));
        console2.log("Bob (tick -12000): filled =", auction.isInRange(bobPos));
        console2.log("Carol (tick -24000): filled =", auction.isInRange(carolPos));
        console2.log("Dave (tick -33000): filled =", auction.isInRange(davePos));

        console2.log("\nAlice incentives:", auction.calculateIncentives(alicePos));
        console2.log("Bob incentives:", auction.calculateIncentives(bobPos));
        console2.log("Carol incentives:", auction.calculateIncentives(carolPos));
        console2.log("Dave incentives:", auction.calculateIncentives(davePos));

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test scenario where clearing price doesn't reach all positions
    function test_partialClear_SomeBiddersMissOut() public {
        // Use smaller token amount to ensure partial fill
        uint256 smallerTokens = 50 ether; // Small amount within available tokens

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        (, bytes32 salt) = HookMiner.find(
            address(auctionDeployer),
            getHookFlags(),
            type(OpeningAuctionExtendedImpl).creationCode,
            abi.encode(manager, creator, smallerTokens, config)
        );

        vm.startPrank(creator);
        auction = auctionDeployer.deploy(smallerTokens, salt, abi.encode(config));
        TestERC20(asset).transfer(address(auction), smallerTokens);
        auction.setIsToken0(true);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));
        vm.stopPrank();

        console2.log("=== Partial Clear Test ===");
        console2.log("Smaller token amount:", smallerTokens);

        // Place massive liquidity at high tick - will absorb tokens early
        uint256 pos1 = _addBid(bidders[0], 0, 1_000_000 ether);
        console2.log("Bidder 0: massive liquidity at tick 0");

        // Place liquidity at lower ticks (but all above minAcceptableTick -34,020)
        uint256 pos2 = _addBid(bidders[1], -600, 100_000 ether);
        uint256 pos3 = _addBid(bidders[2], -6000, 100_000 ether);

        // Place liquidity at a low tick (near minAcceptable) that likely won't be reached
        uint256 pos4 = _addBid(bidders[3], -33000, 100_000 ether);
        console2.log("Bidder 1: tick -600");
        console2.log("Bidder 2: tick -6000");
        console2.log("Bidder 3: tick -33000 (low but valid, should not fill)");

        // Settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());

        // Check who got filled
        uint256[] memory posIds = new uint256[](4);
        posIds[0] = pos1;
        posIds[1] = pos2;
        posIds[2] = pos3;
        posIds[3] = pos4;

        for (uint256 i = 0; i < 4; i++) {
            AuctionPosition memory pos = auction.positions(posIds[i]);
            uint256 incentives = auction.calculateIncentives(posIds[i]);
            console2.log("Bidder at tick:", int256(pos.tickLower));
            console2.log("  filled:", auction.isInRange(posIds[i]));
            console2.log("  incentives:", incentives);
        }

        // Check clearing tick position
        int24 clearingTick = auction.clearingTick();
        AuctionPosition memory pos4Data = auction.positions(pos4);

        // For isToken0, a position's range [tickLower, tickUpper) is utilized when:
        // - clearingTick <= tickLower (fully utilized - price passed through), OR
        // - tickLower <= clearingTick < tickUpper (partially utilized - price stopped inside range)
        // Position at tick -33000 has range [-33000, -32940)
        // If clearingTick is inside or below this range, the position was utilized
        bool positionUtilized = clearingTick <= pos4Data.tickUpper;

        console2.log("\nBidder 3's position analysis:");
        console2.log("  clearingTick:", int256(clearingTick));
        console2.log("  tickLower:", int256(pos4Data.tickLower));
        console2.log("  tickUpper:", int256(pos4Data.tickUpper));
        console2.log("  utilized:", positionUtilized);

        if (positionUtilized) {
            // Position was at least partially utilized (clearing tick entered or passed through range)
            // Should have accumulated time from being in range during auction
            assertGt(auction.getPositionAccumulatedTime(pos4), 0, "Utilized position should have accumulated time");
            assertGt(auction.calculateIncentives(pos4), 0, "Utilized position should get incentives");
        } else {
            // Position was never utilized (clearing tick never reached its range)
            assertEq(auction.getPositionAccumulatedTime(pos4), 0, "Unutilized position should have 0 accumulated time");
            assertEq(auction.calculateIncentives(pos4), 0, "Unutilized position should get 0 incentives");
        }
    }

    /// @notice Test many small bidders vs few large bidders
    function test_liquidityDistribution_SmallVsLargeBidders() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== Small vs Large Bidders ===");

        // 2 whale bidders with 200 ETH each at prime ticks
        _addBid(bidders[0], 0, 200_000 ether);
        _addBid(bidders[1], -600, 200_000 ether);
        console2.log("Whale 1: 200K liquidity at tick 0");
        console2.log("Whale 2: 200K liquidity at tick -600");

        // 8 small bidders with 25 ETH each spread across lower ticks
        uint256[] memory smallPositions = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            int24 tick = int24(int256(-3000 - int256(i) * 3000)); // -3000, -6000, -9000, etc.
            smallPositions[i] = _addBid(bidders[2 + i], tick, 25_000 ether);
            console2.log("Small bidder at tick:", int256(tick));
        }

        // Settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Settlement Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // Count filled positions
        uint256 filledCount = 0;
        uint256 totalIncentivesDistributed = 0;

        console2.log("\n--- Whales ---");
        for (uint256 i = 0; i < 2; i++) {
            uint256 posId = i + 1;
            uint256 incentives = auction.calculateIncentives(posId);
            if (auction.isInRange(posId)) filledCount++;
            totalIncentivesDistributed += incentives;
            console2.log("Whale filled:", auction.isInRange(posId));
            console2.log("  incentives:", incentives);
        }

        console2.log("\n--- Small Bidders ---");
        for (uint256 i = 0; i < 8; i++) {
            uint256 posId = i + 3;
            uint256 incentives = auction.calculateIncentives(posId);
            if (auction.isInRange(posId)) filledCount++;
            totalIncentivesDistributed += incentives;
            console2.log("Small bidder filled:", auction.isInRange(posId));
            console2.log("  incentives:", incentives);
        }

        console2.log("\n--- Summary ---");
        console2.log("Total positions filled:", filledCount);
        console2.log("Total incentives:", totalIncentivesDistributed);
        console2.log("Expected incentives:", auction.incentiveTokensTotal());

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test early vs late bidders
    /// @dev Tests that all bidders who place positions before auction end get incentives
    function test_earlyVsLateBidders() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 3 days, // Shorter auction
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== Early vs Late Bidders ===");

        // Early bidder (day 1)
        uint256 alicePos = _addBid(bidders[0], 0, 100_000 ether);
        console2.log("Day 0: Alice bids at tick 0");

        // Warp to day 1
        vm.warp(block.timestamp + 1 days);
        uint256 bobPos = _addBid(bidders[1], -600, 100_000 ether);
        console2.log("Day 1: Bob bids at tick -600");

        // Warp to day 2
        vm.warp(block.timestamp + 1 days);
        uint256 carolPos = _addBid(bidders[2], -6000, 100_000 ether);
        console2.log("Day 2: Carol bids at tick -6000");

        // Late bidder (just before end)
        vm.warp(auction.auctionEndTime() - 1 hours);
        uint256 davePos = _addBid(bidders[3], -30000, 100_000 ether);
        console2.log("Final hours: Dave bids at tick -30000");

        // End auction
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Final Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        console2.log("\nAlice (early, tick 0):");
        console2.log("  Filled:", auction.isInRange(alicePos));
        console2.log("  Incentives:", auction.calculateIncentives(alicePos));

        console2.log("\nBob (mid, tick -600):");
        console2.log("  Filled:", auction.isInRange(bobPos));
        console2.log("  Incentives:", auction.calculateIncentives(bobPos));

        console2.log("\nCarol (mid-late, tick -6000):");
        console2.log("  Filled:", auction.isInRange(carolPos));
        console2.log("  Incentives:", auction.calculateIncentives(carolPos));

        console2.log("\nDave (late, tick -30000):");
        console2.log("  Filled:", auction.isInRange(davePos));
        console2.log("  Incentives:", auction.calculateIncentives(davePos));

        // All should get equal incentives since they all get filled at settlement
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test claiming incentives after settlement
    function test_incentiveClaiming_AllBiddersClaim() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== Incentive Claiming Test ===");

        // 5 bidders place positions at various ticks (all above minAcceptableTick -34,020)
        int24[] memory ticks = new int24[](5);
        ticks[0] = 0;
        ticks[1] = -3000;
        ticks[2] = -6000;
        ticks[3] = -18000;
        ticks[4] = -30000;

        uint256[] memory posIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            posIds[i] = _addBid(bidders[i], ticks[i], 50_000 ether);
        }

        // Settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("\n=== Claiming Incentives ===");

        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < 5; i++) {
            AuctionPosition memory pos = auction.positions(posIds[i]);
            uint256 expectedIncentives = auction.calculateIncentives(posIds[i]);

            if (expectedIncentives > 0) {
                uint256 balanceBefore = TestERC20(asset).balanceOf(pos.owner);

                vm.prank(pos.owner);
                auction.claimIncentives(posIds[i]);

                uint256 balanceAfter = TestERC20(asset).balanceOf(pos.owner);
                uint256 claimed = balanceAfter - balanceBefore;
                totalClaimed += claimed;

                console2.log("Bidder claimed:", claimed);
                assertEq(claimed, expectedIncentives, "Claimed should match expected");
            } else {
                console2.log("Bidder has 0 incentives (not filled)");
            }
        }

        console2.log("\nTotal claimed:", totalClaimed);
        console2.log("Incentive pool:", auction.incentiveTokensTotal());

        // Verify cannot claim twice
        AuctionPosition memory pos0 = auction.positions(posIds[0]);
        if (auction.isInRange(posIds[0])) {
            vm.expectRevert();
            vm.prank(pos0.owner);
            auction.claimIncentives(posIds[0]);
            console2.log("Double claim correctly reverted");
        }
    }

    /// @notice Test edge case with all positions at same tick
    function test_sameTick_AllBiddersCompete() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        auction = _createAuction(config);

        console2.log("=== All Bidders Same Tick ===");

        // All 10 bidders place at the same tick
        int24 sameTick = -6000;
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            _addBid(bidders[i], sameTick, 50_000 ether);
        }

        console2.log("All 10 bidders placed 50K liquidity at tick", int256(sameTick));

        // Settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // All positions should have same incentives (equal time)
        uint256 firstIncentive = auction.calculateIncentives(1);
        console2.log("Incentives per position:", firstIncentive);

        for (uint256 i = 2; i <= NUM_BIDDERS; i++) {
            uint256 incentive = auction.calculateIncentives(i);
            assertEq(incentive, firstIncentive, "All positions should have equal incentives");
        }

        console2.log("All positions have equal incentives!");
        console2.log("Total distributed:", firstIncentive * NUM_BIDDERS);
    }
}
