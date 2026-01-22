// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionTestImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionTestDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @notice Comprehensive settlement test for Opening Auction
/// @dev Tests various scenarios with in-range and out-of-range positions
contract OpeningAuctionSettlementTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Users - multiple bidders
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address carol = address(0xca401);
    address dave = address(0xda7e);
    address eve = address(0xe7e);
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionTestDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    // Auction parameters - use smaller amounts for tests since liquidity provided is limited
    uint256 constant AUCTION_TOKENS = 100 ether;  // 100 tokens (realistic for test liquidity)
    uint256 constant AUCTION_DURATION = 1 days;

    // Test configuration
    int24 tickSpacing = 60;
    int24 maxTick;
    int24 minAcceptableTick;

    function _currentTick() internal view returns (int24) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

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

        // Deploy auction deployer
        auctionDeployer = new OpeningAuctionTestDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate tick values
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);
        minAcceptableTick = -34_020; // ~0.033 price floor (e.g., 10k USD min raise at 3k ETH for 100 tokens)

        // Fund users with substantial amounts
        _fundUser(alice, 100_000 ether, 100_000 ether);
        _fundUser(bob, 100_000 ether, 100_000 ether);
        _fundUser(carol, 100_000 ether, 100_000 ether);
        _fundUser(dave, 100_000 ether, 100_000 ether);
        _fundUser(eve, 100_000 ether, 100_000 ether);
        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
    }

    function _fundUser(address user, uint256 amount0, uint256 amount1) internal {
        TestERC20(token0).transfer(user, amount0);
        TestERC20(token1).transfer(user, amount1);
    }

    function getHookFlags() internal pure returns (uint160) {
        return OpeningAuctionTestDefaults.hookFlags();
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
            type(OpeningAuctionTestImpl).creationCode,
            constructorArgs
        );
    }

    function _createAuction(OpeningAuctionConfig memory config) internal returns (OpeningAuction) {
        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
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

        return auction.getPositionId(user, tickLower, tickUpper, salt);
    }

    /// @notice Test settlement with many positions spread across tick range
    /// @dev This test creates positions at various tick levels to ensure
    ///      some end up in-range and some out-of-range after settlement
    function test_settlement_WithSpreadPositions() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000, // 10%
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Initial State ===");
        console2.log("Max tick:", int256(maxTick));
        console2.log("Min acceptable tick:", int256(minAcceptableTick));

        // Create positions at various tick levels
        // Higher ticks = higher price = more likely to fill
        // Lower ticks = lower price = less likely to fill

        // Tier 1: High tick positions (close to current price) - WILL fill
        // These are at tick 0 which is way below MAX_TICK, so they'll fill when price drops
        int24 highTick1 = 0;
        int24 highTick2 = highTick1 - tickSpacing;

        // Tier 2: Medium tick positions - MAY fill depending on volume
        int24 medTick1 = -30000;

        // Tier 3: Low tick positions (close to min) - UNLIKELY to fill
        int24 lowTick1 = minAcceptableTick + tickSpacing * 5;
        int24 lowTick2 = minAcceptableTick + tickSpacing * 10;

        console2.log("\n=== Placing Bids ===");

        // Alice: High tick bid with high liquidity - should definitely fill
        uint256 alicePos = _addBid(alice, highTick1, 50_000 ether);
        console2.log("Alice posId:", alicePos);

        // Bob: High tick bid - should fill
        uint256 bobPos = _addBid(bob, highTick2, 30_000 ether);
        console2.log("Bob posId:", bobPos);

        // Carol: Medium tick bid - may fill
        uint256 carolPos = _addBid(carol, medTick1, 40_000 ether);
        console2.log("Carol posId:", carolPos);

        // Dave: Low tick bid - unlikely to fill
        uint256 davePos = _addBid(dave, lowTick1, 20_000 ether);
        console2.log("Dave posId:", davePos);

        // Eve: Very low tick bid - very unlikely to fill
        uint256 evePos = _addBid(eve, lowTick2, 15_000 ether);
        console2.log("Eve posId:", evePos);

        // Check initial position states
        console2.log("\n=== Position States Before Settlement ===");
        _logPositionState("Alice", alicePos);
        _logPositionState("Bob", bobPos);
        _logPositionState("Carol", carolPos);
        _logPositionState("Dave", davePos);
        _logPositionState("Eve", evePos);

        // Warp halfway through auction and check incentive accumulation
        console2.log("\n=== Warping 12 hours ===");
        vm.warp(auction.auctionStartTime() + 12 hours);

        // Check which positions are locked (in range)

        // Warp to end
        console2.log("\n=== Warping to Auction End ===");
        vm.warp(auction.auctionEndTime() + 1);

        // Capture state before settlement
        uint256 hookAssetBefore = TestERC20(asset).balanceOf(address(auction));
        uint256 hookNumeraireBefore = TestERC20(numeraire).balanceOf(address(auction));

        console2.log("Hook asset before:", hookAssetBefore);
        console2.log("Hook numeraire before:", hookNumeraireBefore);

        // Settle the auction
        console2.log("\n=== Settling Auction ===");
        auction.settleAuction();

        console2.log("\n=== Settlement Results ===");
        console2.log("Phase:", uint8(auction.phase()));
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Proceeds:", auction.totalProceeds());
        console2.log("Total accumulated time:", auction.totalAccumulatedTime());

        bool aliceInRange = auction.isInRange(alicePos);
        bool bobInRange = auction.isInRange(bobPos);
        bool carolInRange = auction.isInRange(carolPos);
        bool daveInRange = auction.isInRange(davePos);
        bool eveInRange = auction.isInRange(evePos);

        uint256 inRangeCount = (aliceInRange ? 1 : 0)
            + (bobInRange ? 1 : 0)
            + (carolInRange ? 1 : 0)
            + (daveInRange ? 1 : 0)
            + (eveInRange ? 1 : 0);

        // Check final balances
        uint256 hookAssetAfter = TestERC20(asset).balanceOf(address(auction));
        uint256 hookNumeraireAfter = TestERC20(numeraire).balanceOf(address(auction));

        console2.log("\nHook asset after:", hookAssetAfter);
        console2.log("Hook numeraire after:", hookNumeraireAfter);

        // Verify settlement occurred
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
        assertGt(auction.totalTokensSold(), 0, "Should have sold tokens");
        assertGt(auction.totalProceeds(), 0, "Should have received proceeds");
        assertGt(inRangeCount, 0, "Expected at least one in-range position");
        assertLt(inRangeCount, 5, "Expected at least one out-of-range position");

        // Log position states after settlement
        console2.log("\n=== Position States After Settlement ===");
        _logPositionState("Alice", alicePos);
        _logPositionState("Bob", bobPos);
        _logPositionState("Carol", carolPos);
        _logPositionState("Dave", davePos);
        _logPositionState("Eve", evePos);

        // Calculate and log incentives
        console2.log("\n=== Incentive Calculations ===");
        console2.log("Total incentive tokens:", auction.incentiveTokensTotal());
        _logIncentives("Alice", alicePos);
        _logIncentives("Bob", bobPos);
        _logIncentives("Carol", carolPos);
        _logIncentives("Dave", davePos);
        _logIncentives("Eve", evePos);

        // Verify that at least some positions accumulated time
        assertGt(auction.totalAccumulatedTime(), 0, "Should have accumulated time");
    }

    /// @notice Test that positions entering and exiting range accumulate correct time
    function test_settlement_IncentiveTimeAccumulation() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: 4 hours, // Shorter auction for easier testing
            minAcceptableTickToken0: -34_020, // ~0.033 price floor
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000, // 10%
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Incentive Time Accumulation Test ===");
        console2.log("Auction duration:", auction.auctionDuration());
        console2.log("Starting tick:", int256(_currentTick()));

        // Alice starts in range at a low tick
        int24 aliceTick = -30_000;
        uint128 aliceLiquidity = 100_000 ether;
        uint256 alicePos = _addBid(alice, aliceTick, aliceLiquidity);

        AuctionPosition memory alicePosition = auction.positions(alicePos);
        console2.log("\nAlice position placed at tick:", int256(aliceTick));
        console2.log("Initial isInRange:", auction.isInRange(alicePos));
        console2.log("Initial rewardDebtX128:", alicePosition.rewardDebtX128);

        assertTrue(auction.isInRange(alicePos), "Alice should be in range initially");

        // Warp 2 hours to accumulate time
        vm.warp(block.timestamp + 2 hours);
        uint256 aliceTimeBeforePush = auction.getPositionAccumulatedTime(alicePos);
        console2.log("Alice accumulated time (2h):", aliceTimeBeforePush);

        // Bob adds a large bid at a higher tick to push Alice out of range
        int24 bobTick = 0;
        uint128 bobLiquidity = 500_000 ether;
        uint256 bobPos = _addBid(bob, bobTick, bobLiquidity);

        console2.log("Bob position placed at tick:", int256(bobTick));
        console2.log("Alice in range after Bob:", auction.isInRange(alicePos));
        console2.log("Bob in range after Bob:", auction.isInRange(bobPos));

        assertFalse(auction.isInRange(alicePos), "Alice should be pushed out of range");
        assertTrue(auction.isInRange(bobPos), "Bob should be in range");

        uint256 expectedAliceTime = aliceLiquidity * 2 hours;
        assertApproxEqAbs(
            aliceTimeBeforePush,
            expectedAliceTime,
            aliceLiquidity * 5 minutes,
            "Alice time should match ~2 hours of accumulation"
        );

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Alice time should not increase while out of range
        uint256 aliceTimeFinal = auction.getPositionAccumulatedTime(alicePos);
        assertApproxEqAbs(aliceTimeFinal, aliceTimeBeforePush, 10, "Alice time should stop after being pushed out");

        // Settle
        auction.settleAuction();

        console2.log("\n=== After Settlement ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        uint256 bobIncentives = auction.calculateIncentives(bobPos);
        console2.log("Alice incentives:", aliceIncentives);
        console2.log("Bob incentives:", bobIncentives);

        assertGt(aliceIncentives, 0, "Alice should have incentives from time in range");
        assertGt(bobIncentives, 0, "Bob should have incentives");
    }

    /// @notice Test with positions that definitely stay out of range
    function test_settlement_OutOfRangePositions() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020, // ~0.033 price floor
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        console2.log("=== Out of Range Positions Test ===");

        // Place a small liquidity position at a high tick
        // This will fill immediately, limiting how far the price can fall
        int24 highTick = 0;
        _addBid(alice, highTick, 1_000_000 ether);

        // Place a position at a very low tick - this should stay out of range
        int24 lowTick = minAcceptableTick + tickSpacing * 2;
        uint256 lowPosId = _addBid(bob, lowTick, 50_000 ether);

        console2.log("Low position tick:", int256(lowTick));
        console2.log("Low position isInRange:", auction.isInRange(lowPosId));

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== After Settlement ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));

        uint256 lowAccTime = auction.getPositionAccumulatedTime(lowPosId);
        console2.log("Low position final accumulatedTime:", lowAccTime);

        uint256 lowIncentives = auction.calculateIncentives(lowPosId);
        console2.log("Low position incentives:", lowIncentives);

        int24 clearingTick = auction.clearingTick();
        assertGt(clearingTick, lowTick + tickSpacing, "Clearing tick should stay above low position");
        assertEq(lowAccTime, 0, "Out-of-range position should have 0 accumulated time");
        assertEq(lowIncentives, 0, "Out-of-range position should have 0 incentives");
    }

    /// @notice Test claiming incentives after settlement
    function test_settlement_ClaimIncentives() public {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020, // ~0.033 price floor
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        auction = _createAuction(config);

        // Place bid that will be in range
        int24 bidTick = 0;
        uint256 posId = _addBid(alice, bidTick, 50_000 ether);

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // Migrate before claiming incentives
        vm.prank(creator);
        auction.migrate(address(this));

        // Get the position owner (it's the modifyLiquidityRouter)
        AuctionPosition memory pos = auction.positions(posId);

        uint256 incentives = auction.calculateIncentives(posId);
        console2.log("Incentives to claim:", incentives);

        if (incentives > 0) {
            uint256 ownerBalanceBefore = TestERC20(asset).balanceOf(pos.owner);

            // Claim incentives (from the router since it's the owner)
            vm.prank(pos.owner);
            auction.claimIncentives(posId);

            uint256 ownerBalanceAfter = TestERC20(asset).balanceOf(pos.owner);
            console2.log("Balance before:", ownerBalanceBefore);
            console2.log("Balance after:", ownerBalanceAfter);
            console2.log("Received:", ownerBalanceAfter - ownerBalanceBefore);

            assertEq(ownerBalanceAfter - ownerBalanceBefore, incentives, "Should receive correct incentives");

            // Verify cannot claim twice
            vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AlreadyClaimed()"))));
            vm.prank(pos.owner);
            auction.claimIncentives(posId);
        }
    }

    /// @notice Test partial fill scenario where some positions stay unfilled
    /// @dev This test uses massive liquidity at high ticks to prevent price from falling all the way
    function test_settlement_PartialFill_SomePositionsUnfilled() public {
        // Use a smaller token amount so that liquidity can absorb it
        uint256 smallAuctionTokens = 50 ether; // Small amount within available tokens

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000, // 10%
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        // Mine salt for smaller auction
        (, bytes32 salt) = HookMiner.find(
            address(auctionDeployer),
            getHookFlags(),
            type(OpeningAuctionTestImpl).creationCode,
            abi.encode(manager, creator, smallAuctionTokens, config)
        );

        // Deploy auction with small token amount
        vm.startPrank(creator);
        auction = auctionDeployer.deploy(
            smallAuctionTokens,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(auction), smallAuctionTokens);
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

        console2.log("=== Partial Fill Test ===");
        console2.log("Auction tokens:", smallAuctionTokens);
        console2.log("Starting tick:", int256(_currentTick()));

        // Place a large amount of liquidity at tick 0 (within user budget)
        // This will absorb all the tokens before price falls below 0
        int24 highTick = 0;
        uint256 highPosId = _addBid(alice, highTick, 90_000 ether); // Large but within budget
        console2.log("Alice: massive liquidity at tick 0");

        // Place medium liquidity at a lower tick (must be aligned to tickSpacing 60)
        int24 medTick = -1020; // Aligned to 60
        uint256 medPosId = _addBid(bob, medTick, 50_000 ether);
        console2.log("Bob: medium liquidity at tick", int256(medTick));

        // Place small liquidity at a lower tick (but above minAcceptable) - may not be filled
        int24 lowTick = -33000; // Above minAcceptableTick (-34,020), aligned to 60
        uint256 lowPosId = _addBid(carol, lowTick, 10_000 ether);
        console2.log("Carol: small liquidity at tick", int256(lowTick));

        // Warp and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        console2.log("\n=== After Settlement ===");
        console2.log("Clearing tick:", int256(auction.clearingTick()));
        console2.log("Tokens sold:", auction.totalTokensSold());
        console2.log("Total accumulated time:", auction.totalAccumulatedTime());

        console2.log("\nAlice (tick 0): isInRange =", auction.isInRange(highPosId));
        console2.log("  accumulatedTime:", auction.getPositionAccumulatedTime(highPosId));
        console2.log("  incentives:", auction.calculateIncentives(highPosId));

        console2.log("\nBob (tick -1000): isInRange =", auction.isInRange(medPosId));
        console2.log("  accumulatedTime:", auction.getPositionAccumulatedTime(medPosId));
        console2.log("  incentives:", auction.calculateIncentives(medPosId));

        console2.log("\nCarol (tick -50000): isInRange =", auction.isInRange(lowPosId));
        console2.log("  accumulatedTime:", auction.getPositionAccumulatedTime(lowPosId));
        console2.log("  incentives:", auction.calculateIncentives(lowPosId));

        // Verify that clearing tick is above the low tick position
        // If clearing tick > lowTick, Carol's position was NOT filled
        int24 clearingTick = auction.clearingTick();

        uint256 carolAccTime = auction.getPositionAccumulatedTime(lowPosId);
        assertGt(clearingTick, lowTick + tickSpacing, "Clearing tick should stay above low position");
        console2.log("\nCarol's position was NOT filled (clearing tick above position range)");
        assertEq(carolAccTime, 0, "Unfilled position should have 0 accumulated time");
        assertEq(auction.calculateIncentives(lowPosId), 0, "Unfilled position should have 0 incentives");

        // Verify assertions
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Helper to log position state
    function _logPositionState(string memory name, uint256 posId) internal view {
        AuctionPosition memory pos = auction.positions(posId);
        console2.log(string.concat(name, " - tick:"), int256(pos.tickLower));
        console2.log(string.concat(name, " - inRange:"), auction.isInRange(posId));
        console2.log(string.concat(name, " - liquidity:"), pos.liquidity);
        console2.log(string.concat(name, " - accTime:"), auction.getPositionAccumulatedTime(posId));
    }

    /// @notice Helper to log incentives
    function _logIncentives(string memory name, uint256 posId) internal view {
        uint256 incentives = auction.calculateIncentives(posId);
        console2.log(string.concat(name, " incentives:"), incentives);
    }
}
