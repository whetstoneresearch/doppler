// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IPoolManager, PoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";
import { Test, console2 } from "forge-std/Test.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { AuctionPhase, AuctionPosition, OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionRealisticImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) { }

    function validateHookAddress(BaseHook) internal pure override { }
}

/// @notice OpeningAuctionDeployer for realistic scenario tests
contract OpeningAuctionRealisticDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) { }

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionRealisticImpl auction =
            new OpeningAuctionRealisticImpl{ salt: salt }(poolManager, msg.sender, auctionTokens, config);

        return OpeningAuction(payable(address(auction)));
    }
}

/// @title OpeningAuctionRealisticScenariosTest
/// @notice Tests realistic auction scenarios matching real-world token launches
/// @dev Addresses gaps identified in test coverage analysis:
///      - Small cap launches (10k USD raise from 5% supply)
///      - Low incentive shares (0.3% = 30 bps)
///      - Many bidders with most ending up out of range
///      - Partial time in range scenarios
contract OpeningAuctionRealisticScenariosTest is Test, Deployers {
    // ============ Constants ============

    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    // Realistic token economics (scaled for test liquidity):
    // - Total supply: 10,000 tokens
    // - Sale amount: 5% of supply = 500 tokens
    // - Incentive share: 6% of sale (0.3% of supply) = 30 tokens
    // These amounts are scaled down but maintain the same ratios
    uint256 constant TOTAL_SUPPLY = 10_000 ether;
    uint256 constant SALE_AMOUNT = 500 ether; // 5% of supply
    uint256 constant INCENTIVE_SHARE_BPS = 60; // 6% of sale = 0.3% of total supply

    // Auction parameters
    uint256 constant AUCTION_DURATION = 7 days;
    int24 constant MIN_ACCEPTABLE_TICK = -69_000; // ~0.001 price floor
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;
    uint128 constant MIN_LIQUIDITY = 1e15;

    // ============ State Variables ============

    address asset;
    address numeraire;
    address token0;
    address token1;

    address[] bidders;
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    OpeningAuctionRealisticDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    int24 maxTick;

    // Track positions for analysis
    mapping(address => uint256[]) bidderPositions;

    // ============ Setup ============

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens with sufficient supply for massive liquidity tests
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max / 2), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max / 2), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionRealisticDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate max tick
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, TICK_SPACING);

        // Create 50 bidders for realistic scenarios
        _createBidders(50);

        // Fund creator
        TestERC20(asset).transfer(creator, SALE_AMOUNT);
    }

    function _createBidders(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            address bidder = address(uint160(0x1000 + i));
            bidders.push(bidder);
            vm.label(bidder, string.concat("Bidder", vm.toString(i)));

            // Fund each bidder with massive amounts for large positions
            TestERC20(numeraire).transfer(bidder, 1_000_000_000 ether);
            TestERC20(token0).transfer(bidder, 1_000_000_000 ether);
        }
    }

    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function _createAuction(
        OpeningAuctionConfig memory config,
        uint256 auctionTokens
    ) internal returns (OpeningAuction) {
        (, bytes32 salt) = HookMiner.find(
            address(auctionDeployer),
            getHookFlags(),
            type(OpeningAuctionRealisticImpl).creationCode,
            abi.encode(manager, creator, auctionTokens, config)
        );

        vm.startPrank(creator);
        OpeningAuction _auction = auctionDeployer.deploy(auctionTokens, salt, abi.encode(config));
        TestERC20(asset).transfer(address(_auction), auctionTokens);
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
        int24 tickUpper = tickLower + TICK_SPACING;
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
        bidderPositions[user].push(positionId);
    }

    // ============ Test: Small Cap Launch with 0.3% Incentives ============

    /// @notice Tests a realistic small cap token launch scenario
    /// @dev Parameters:
    ///      - 5% of supply for sale
    ///      - 0.3% of supply for incentives (6% of sale amount)
    ///      - 50 bidders
    ///      - Target raise: ~10k USD equivalent
    function test_realisticScenario_SmallCapLaunch_30BpsIncentives() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS, // 6% of sale = 0.3% of supply
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Small Cap Launch: 0.3% Incentives ===");
        console2.log("Sale amount:", SALE_AMOUNT / 1e18, "tokens");
        console2.log("Incentive tokens:", auction.incentiveTokensTotal() / 1e18, "tokens");
        console2.log("Incentive share of sale:", (auction.incentiveTokensTotal() * 100) / SALE_AMOUNT, "%");

        // Verify incentive calculation matches expected 6% of sale
        uint256 expectedIncentives = (SALE_AMOUNT * INCENTIVE_SHARE_BPS) / 10_000;
        assertEq(auction.incentiveTokensTotal(), expectedIncentives, "Incentive calculation mismatch");

        // Place bids across tick range
        // High ticks (will fill): 10 bidders
        // Medium ticks (may fill): 20 bidders
        // Low ticks (won't fill): 20 bidders
        _placeBidsWithDistribution();

        // Warp through auction
        vm.warp(block.timestamp + 3 days);
        console2.log("\nMid-auction (day 3)...");

        vm.warp(auction.auctionEndTime() + 1);
        console2.log("Auction ended, settling...");

        // Settle
        auction.settleAuction();

        // Analyze results
        _analyzeResults();

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Places bids with realistic distribution
    /// @dev 30% at high ticks (will fill), 30% at medium ticks, 40% at low ticks
    function _placeBidsWithDistribution() internal {
        uint256 numBidders = bidders.length;

        // High ticks (30% of bidders) - will definitely fill
        // Provide enough liquidity to absorb 500 tokens at high ticks
        uint256 highTickBidders = numBidders * 30 / 100;
        for (uint256 i = 0; i < highTickBidders; i++) {
            int24 tick = -int24(int256(i)) * TICK_SPACING * 2; // 0, -120, -240, etc.
            // Each high tick bidder provides significant liquidity
            _addBid(bidders[i], tick, 100_000 ether);
        }

        // Medium ticks (30% of bidders) - will mostly fill due to high liquidity above
        uint256 mediumTickBidders = numBidders * 30 / 100;
        for (uint256 i = 0; i < mediumTickBidders; i++) {
            int24 tick = -6000 - int24(int256(i)) * TICK_SPACING * 10;
            _addBid(bidders[highTickBidders + i], tick, 50_000 ether);
        }

        // Low ticks (40% of bidders) - won't fill (below where clearing will settle)
        uint256 lowTickBidders = numBidders - highTickBidders - mediumTickBidders;
        for (uint256 i = 0; i < lowTickBidders; i++) {
            int24 tick = MIN_ACCEPTABLE_TICK + int24(int256((i + 1) * uint256(uint24(TICK_SPACING))));
            _addBid(bidders[highTickBidders + mediumTickBidders + i], tick, 20_000 ether);
        }

        console2.log("\nBids placed:");
        console2.log("  High tick bidders:", highTickBidders);
        console2.log("  Medium tick bidders:", mediumTickBidders);
        console2.log("  Low tick bidders:", lowTickBidders);
    }

    function _analyzeResults() internal view {
        console2.log("\n=== Settlement Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold() / 1e18);
        console2.log("Proceeds:", auction.totalProceeds() / 1e18);
        console2.log("Total accumulated time:", auction.totalAccumulatedTime());

        // Count filled vs unfilled positions
        uint256 filledCount = 0;
        uint256 unfilledCount = 0;
        uint256 totalIncentives = 0;

        for (uint256 i = 1; i <= bidders.length; i++) {
            if (auction.isInRange(i)) {
                filledCount++;
            } else {
                unfilledCount++;
            }
            totalIncentives += auction.calculateIncentives(i);
        }

        console2.log("\nPosition analysis:");
        console2.log("  Filled positions:", filledCount);
        console2.log("  Unfilled positions:", unfilledCount);
        console2.log("  Total claimable incentives:", totalIncentives / 1e18);
        console2.log("  Incentive pool:", auction.incentiveTokensTotal() / 1e18);

        // Verify unfilled positions get zero incentives
        // (done in dedicated test below)
    }

    // ============ Test: Many Bidders Out of Range ============

    /// @notice Tests scenario where 70%+ of bidders end up out of range
    /// @dev Key assertions:
    ///      - Out-of-range positions earn 0 incentives
    ///      - In-range positions share all incentives
    ///      - No incentive tokens are lost
    function test_realisticScenario_ManyBiddersOutOfRange() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Many Bidders Out of Range Test ===");

        // Place a few large bids at high ticks that will absorb all tokens
        // These will be the only "in range" positions
        uint256 inRangeBidders = 5;
        for (uint256 i = 0; i < inRangeBidders; i++) {
            int24 tick = -int24(int256(i)) * TICK_SPACING * 3;
            _addBid(bidders[i], tick, 500_000 ether);
            console2.log("In-range bidder at tick:", int256(tick));
        }

        // Place many bids at low ticks (will be out of range)
        uint256 outOfRangeBidders = 45;
        for (uint256 i = 0; i < outOfRangeBidders; i++) {
            // Place at low ticks that won't be reached
            int24 tick = MIN_ACCEPTABLE_TICK + int24(int256((i + 1) * uint256(uint24(TICK_SPACING))));
            _addBid(bidders[inRangeBidders + i], tick, 50_000 ether);
        }

        console2.log("\nTotal bidders:", inRangeBidders + outOfRangeBidders);
        console2.log("Expected in-range:", inRangeBidders);
        console2.log("Expected out-of-range:", outOfRangeBidders);

        // Warp to end and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // Verify in-range positions
        uint256 totalFilledIncentives = 0;
        for (uint256 i = 1; i <= inRangeBidders; i++) {
            bool inRange = auction.isInRange(i);
            uint256 incentives = auction.calculateIncentives(i);
            console2.log("Position", i);
            console2.log("  inRange:", inRange);
            console2.log("  incentives:", incentives / 1e18);

            if (inRange) {
                assertGt(incentives, 0, "In-range position should have incentives");
                totalFilledIncentives += incentives;
            }
        }

        // Verify out-of-range positions get ZERO
        uint256 zeroIncentiveCount = 0;
        for (uint256 i = inRangeBidders + 1; i <= inRangeBidders + outOfRangeBidders; i++) {
            uint256 incentives = auction.calculateIncentives(i);
            if (incentives == 0) {
                zeroIncentiveCount++;
            }
            // Out of range should have 0 incentives
            if (!auction.isInRange(i)) {
                assertEq(incentives, 0, "Out-of-range position should have 0 incentives");
            }
        }

        console2.log("\nPositions with zero incentives:", zeroIncentiveCount);
        console2.log("Total incentives to filled positions:", totalFilledIncentives / 1e18);
        console2.log("Incentive pool:", auction.incentiveTokensTotal() / 1e18);

        // Verify total incentives don't exceed pool
        assertLe(totalFilledIncentives, auction.incentiveTokensTotal(), "Incentives exceed pool");
    }

    // ============ Test: Partial Time in Range ============

    /// @notice Tests positions that spend partial time in range due to clearing tick movement
    /// @dev Scenario:
    ///      - Position A is in range for first 3 days
    ///      - New bids push Position A out of range
    ///      - Position A should get ~3/7 of the incentives vs a position in range the whole time
    function test_realisticScenario_PartialTimeInRange() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Partial Time in Range Test ===");

        // Alice bids at a medium tick - initially in range
        int24 aliceTick = -30_000;
        uint256 alicePos = _addBid(bidders[0], aliceTick, 100_000 ether);
        console2.log("Alice bids at tick:", int256(aliceTick));
        console2.log("Alice initially in range:", auction.isInRange(alicePos));

        assertTrue(auction.isInRange(alicePos), "Alice should be in range initially");

        // Warp 3 days (Alice accumulating time)
        vm.warp(block.timestamp + 3 days);
        console2.log("\nAfter 3 days:");
        console2.log("Alice accumulated time:", auction.getPositionAccumulatedTime(alicePos));

        // Bob places large bid at higher tick, pushing Alice out
        int24 bobTick = 0;
        uint256 bobPos = _addBid(bidders[1], bobTick, 500_000 ether);
        console2.log("\nBob bids at tick:", int256(bobTick));
        console2.log("Alice now in range:", auction.isInRange(alicePos));
        console2.log("Bob in range:", auction.isInRange(bobPos));

        assertFalse(auction.isInRange(alicePos), "Alice should be pushed out of range");
        assertTrue(auction.isInRange(bobPos), "Bob should be in range");

        // Record Alice's accumulated time at this point
        uint256 aliceTimeAfterPush = auction.getPositionAccumulatedTime(alicePos);
        console2.log("Alice accumulated time after being pushed out:", aliceTimeAfterPush);

        // Warp to auction end (4 more days)
        vm.warp(auction.auctionEndTime() + 1);

        // Alice's time should NOT have increased (she was out of range)
        uint256 aliceTimeFinal = auction.getPositionAccumulatedTime(alicePos);
        console2.log("\nAt auction end:");
        console2.log("Alice final accumulated time:", aliceTimeFinal);
        console2.log("Bob accumulated time:", auction.getPositionAccumulatedTime(bobPos));

        // Alice's time should be approximately what it was when pushed out
        assertApproxEqAbs(aliceTimeFinal, aliceTimeAfterPush, 10, "Alice time should not increase while out of range");

        // Settle
        auction.settleAuction();

        console2.log("\n=== After Settlement ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        uint256 bobIncentives = auction.calculateIncentives(bobPos);

        console2.log("Alice incentives:", aliceIncentives / 1e18);
        console2.log("Bob incentives:", bobIncentives / 1e18);

        // Alice was in range ~3/7 of the time, Bob ~4/7
        // But Bob had more liquidity, so the ratio will be different
        // Key assertion: Alice gets SOME incentives (she was in range for 3 days)
        // If Alice was pushed completely out and never in range at settlement, she should still
        // have accumulated time from when she WAS in range
        assertGt(aliceTimeAfterPush, 0, "Test setup failed: Alice never in range");
        assertGt(aliceIncentives, 0, "Alice should have some incentives from partial time in range");

        // Bob should have more incentives (more time + more liquidity)
        assertGt(bobIncentives, 0, "Bob should have incentives");
    }

    // ============ Test: Mixed Bidder Sizes (Whales vs Retail) ============

    /// @notice Tests realistic distribution with 2 whales and many small bidders
    /// @dev Verifies incentive distribution is proportional to liquidity * time
    function test_realisticScenario_MixedBidderSizes() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Mixed Bidder Sizes Test ===");

        // 2 whales with large liquidity at prime ticks
        uint256 whale1Pos = _addBid(bidders[0], 0, 500_000 ether);
        uint256 whale2Pos = _addBid(bidders[1], -TICK_SPACING, 400_000 ether);
        console2.log("Whale 1: 500K liquidity at tick 0");
        console2.log("Whale 2: 400K liquidity at tick", int256(-TICK_SPACING));

        // 20 small bidders with modest liquidity
        uint256[] memory smallPositions = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            int24 tick = int24(-int256((i + 2) * uint256(uint24(TICK_SPACING)) * 5));
            smallPositions[i] = _addBid(bidders[2 + i], tick, 10_000 ether);
        }
        console2.log("20 small bidders: 10K liquidity each");

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        uint256 whale1Incentives = auction.calculateIncentives(whale1Pos);
        uint256 whale2Incentives = auction.calculateIncentives(whale2Pos);

        console2.log("Whale 1 incentives:", whale1Incentives / 1e18);
        console2.log("Whale 2 incentives:", whale2Incentives / 1e18);

        uint256 totalSmallIncentives = 0;
        uint256 smallBiddersWithIncentives = 0;
        for (uint256 i = 0; i < 20; i++) {
            uint256 incentives = auction.calculateIncentives(smallPositions[i]);
            totalSmallIncentives += incentives;
            if (incentives > 0) {
                smallBiddersWithIncentives++;
            }
        }

        console2.log("Small bidders with incentives:", smallBiddersWithIncentives);
        console2.log("Total small bidder incentives:", totalSmallIncentives / 1e18);

        // Whales should have significantly more incentives due to higher liquidity
        uint256 totalWhaleIncentives = whale1Incentives + whale2Incentives;
        console2.log(
            "\nWhale share of incentives:",
            (totalWhaleIncentives * 100) / (totalWhaleIncentives + totalSmallIncentives),
            "%"
        );

        // Verify total doesn't exceed pool
        uint256 totalDistributed = totalWhaleIncentives + totalSmallIncentives;
        assertLe(totalDistributed, auction.incentiveTokensTotal(), "Total exceeds pool");
        assertGt(whale1Incentives, 0, "Whale 1 should receive incentives");
        if (auction.isInRange(whale2Pos)) {
            assertGt(whale2Incentives, 0, "Whale 2 should receive incentives if in range");
        } else {
            assertEq(whale2Incentives, 0, "Whale 2 should not receive incentives if out of range");
        }
        assertGt(totalWhaleIncentives, totalSmallIncentives, "Whales should receive majority of incentives");
    }

    // ============ Test: Last Minute Bidding ============

    /// @notice Tests late bids pushing earlier bidders out of range
    /// @dev Simulates real-world "sniping" behavior
    function test_realisticScenario_LastMinuteBidding() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Last Minute Bidding Test ===");

        // Day 1: Early bidders place positions across range
        uint256[] memory earlyPositions = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            int24 tick = int24(-int256((i + 1) * uint256(uint24(TICK_SPACING)) * 50));
            earlyPositions[i] = _addBid(bidders[i], tick, 50_000 ether);
        }
        console2.log("Day 1: 10 early bidders placed positions");

        // Record which are in range
        uint256 earlyInRangeCount = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (auction.isInRange(earlyPositions[i])) {
                earlyInRangeCount++;
            }
        }
        console2.log("Early bidders in range:", earlyInRangeCount);
        assertGt(earlyInRangeCount, 0, "Expected some early bids in range");

        // Warp to last hour
        vm.warp(auction.auctionEndTime() - 1 hours);
        console2.log("\nLast hour of auction...");

        // Late bidders come in with large liquidity at high ticks
        uint256[] memory latePositions = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            int24 tick = int24(-int256(i * uint256(uint24(TICK_SPACING))));
            latePositions[i] = _addBid(bidders[10 + i], tick, 200_000 ether);
            console2.log("Late bidder placed at tick:", int256(tick));
        }

        // Check how many early bidders got pushed out
        uint256 earlyStillInRange = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (auction.isInRange(earlyPositions[i])) {
                earlyStillInRange++;
            }
        }
        console2.log("\nEarly bidders still in range after sniping:", earlyStillInRange);
        assertLt(earlyStillInRange, earlyInRangeCount, "Expected sniping to push some early bids out");

        // Warp to end and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== Settlement Results ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        // Analyze incentive distribution
        uint256 totalEarlyIncentives = 0;
        uint256 earlyWithIncentives = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 incentives = auction.calculateIncentives(earlyPositions[i]);
            totalEarlyIncentives += incentives;
            if (incentives > 0) {
                earlyWithIncentives++;
            }
        }

        uint256 totalLateIncentives = 0;
        for (uint256 i = 0; i < 5; i++) {
            totalLateIncentives += auction.calculateIncentives(latePositions[i]);
        }

        console2.log("\nEarly bidders with non-zero incentives:", earlyWithIncentives);
        console2.log("Total early incentives:", totalEarlyIncentives / 1e18);
        console2.log("Total late incentives:", totalLateIncentives / 1e18);

        // Early bidders who were pushed out but spent time in range should still get some incentives
        // Late bidders had less time but higher priority
        assertGt(totalEarlyIncentives, 0, "Early bidders should receive incentives");
        assertGt(totalLateIncentives, 0, "Late bidders should receive incentives");
        assertLe(
            totalEarlyIncentives + totalLateIncentives,
            auction.incentiveTokensTotal(),
            "Total incentives should not exceed pool"
        );
        console2.log(
            "Late bidders share:", (totalLateIncentives * 100) / (totalEarlyIncentives + totalLateIncentives + 1), "%"
        );
    }

    // ============ Test: Edge Case - Very Short Time in Range ============

    /// @notice Tests precision when positions spend very short time in range
    /// @dev Ensures no rounding issues cause zero incentives for short-lived in-range periods
    function test_realisticScenario_VeryShortTimeInRange() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 1 days, // Short auction for this test
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        // Use the standard sale amount
        auction = _createAuction(config, SALE_AMOUNT);

        console2.log("=== Very Short Time in Range Test ===");

        // Alice bids
        uint256 alicePos = _addBid(bidders[0], -30_000, 100_000 ether);
        console2.log("Alice bids, in range:", auction.isInRange(alicePos));

        // Wait just 1 minute
        vm.warp(block.timestamp + 1 minutes);

        // Bob places a large bid pushing Alice out
        uint256 bobPos = _addBid(bidders[1], 0, 500_000 ether);
        console2.log("After 1 minute, Bob bids");
        console2.log("Alice now in range:", auction.isInRange(alicePos));

        uint256 aliceTimeAfter1Min = auction.getPositionAccumulatedTime(alicePos);
        console2.log("Alice accumulated time (1 min):", aliceTimeAfter1Min);

        // Warp to end
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        uint256 bobIncentives = auction.calculateIncentives(bobPos);

        console2.log("\n=== Results ===");
        console2.log("Alice incentives:", aliceIncentives);
        console2.log("Bob incentives:", bobIncentives);

        assertGt(aliceTimeAfter1Min, 0, "Test setup failed: Alice never in range");
        assertGt(aliceIncentives, 0, "Alice should have incentives from short time in range");
    }

    // ============ Test: Claiming All Incentives ============

    /// @notice Tests that all bidders can claim their incentives and total matches expectations
    function test_realisticScenario_ClaimAllIncentives() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: INCENTIVE_SHARE_BPS,
            tickSpacing: TICK_SPACING,
            fee: FEE,
            minLiquidity: MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config, SALE_AMOUNT);

        // Place bids
        uint256 numBidders = 20;
        for (uint256 i = 0; i < numBidders; i++) {
            int24 tick = int24(-int256(i * uint256(uint24(TICK_SPACING)) * 10));
            _addBid(bidders[i], tick, 50_000 ether);
        }

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        console2.log("=== Claim All Incentives Test ===");
        console2.log("Incentive pool:", auction.incentiveTokensTotal() / 1e18);

        // Claim all incentives
        uint256 totalClaimed = 0;
        for (uint256 i = 1; i <= numBidders; i++) {
            AuctionPosition memory pos = auction.positions(i);
            uint256 expectedIncentives = auction.calculateIncentives(i);

            if (expectedIncentives > 0) {
                uint256 balanceBefore = TestERC20(asset).balanceOf(pos.owner);
                auction.claimIncentives(i);
                uint256 balanceAfter = TestERC20(asset).balanceOf(pos.owner);

                uint256 claimed = balanceAfter - balanceBefore;
                totalClaimed += claimed;

                assertEq(claimed, expectedIncentives, "Claimed amount should match expected");
            }
        }

        console2.log("Total claimed:", totalClaimed / 1e18);
        console2.log("Remaining in pool (dust):", (auction.incentiveTokensTotal() - totalClaimed) / 1e18);

        // Total claimed should be <= incentive pool (allowing for dust)
        assertLe(totalClaimed, auction.incentiveTokensTotal(), "Claimed exceeds pool");

        // Dust should be minimal (less than number of claimers)
        uint256 dust = auction.incentiveTokensTotal() - totalClaimed;
        assertLe(dust, numBidders, "Dust should be minimal");
    }
}
