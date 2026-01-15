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
import { IOpeningAuction } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionDeployer } from "src/OpeningAuctionInitializer.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionRecoveryImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionRecoveryDeployer is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionRecoveryImpl auction = new OpeningAuctionRecoveryImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @title IncentiveRecoveryTest
/// @notice Tests for the OpeningAuction incentive recovery mechanism
/// @dev The recoverIncentives() function allows the initializer to recover incentive tokens
///      when no positions earned any time (cachedTotalWeightedTimeX128 == 0).
///      This handles edge cases where incentive tokens would otherwise be permanently locked.
contract IncentiveRecoveryTest is Test, Deployers {
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
    address creator = address(0xc4ea70);
    uint256 bidNonce;

    // Contracts
    OpeningAuctionRecoveryDeployer auctionDeployer;
    OpeningAuction auction;
    PoolKey poolKey;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    // Test configuration
    int24 tickSpacing = 60;
    int24 maxTick;
    int24 minAcceptableTick = -34_020;

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
        auctionDeployer = new OpeningAuctionRecoveryDeployer(manager);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Calculate tick values
        maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);

        // Fund users
        _fundUser(alice, 100_000 ether, 100_000 ether);
        _fundUser(bob, 100_000 ether, 100_000 ether);
        TestERC20(asset).transfer(creator, AUCTION_TOKENS);
    }

    function _fundUser(address user, uint256 amount0, uint256 amount1) internal {
        TestERC20(token0).transfer(user, amount0);
        TestERC20(token1).transfer(user, amount1);
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
            type(OpeningAuctionRecoveryImpl).creationCode,
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
    }

    function getDefaultConfig() internal view returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 1000, // 10%
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });
    }

    // ============ Recovery Success Scenarios ============

    /// @notice Test that recovery succeeds when auction settles with zero bids
    /// @dev When no positions exist, cachedTotalWeightedTimeX128 == 0 and recovery should work
    function test_recoverIncentives_SucceedsWithZeroBids() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Warp to auction end without placing any bids
        vm.warp(auction.auctionEndTime() + 1);

        // Settle the auction with no bids
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Verify auction is settled and no time was accumulated
        assertEq(uint8(auction.phase()), uint8(AuctionPhase.Settled), "Auction should be settled");
        assertEq(auction.cachedTotalWeightedTimeX128(), 0, "No time should be accumulated with no bids");

        // Calculate expected incentives
        uint256 expectedIncentives = auction.incentiveTokensTotal();
        assertGt(expectedIncentives, 0, "Should have incentive tokens to recover");

        // Get creator's balance before recovery
        uint256 creatorBalanceBefore = TestERC20(asset).balanceOf(creator);

        // Creator (initializer) recovers incentives
        vm.prank(creator);
        auction.recoverIncentives(creator);

        // Verify tokens were transferred
        uint256 creatorBalanceAfter = TestERC20(asset).balanceOf(creator);
        assertEq(
            creatorBalanceAfter - creatorBalanceBefore,
            expectedIncentives,
            "Creator should receive all incentive tokens"
        );

        // Verify incentiveTokensTotal is now 0 (prevents double recovery)
        assertEq(auction.incentiveTokensTotal(), 0, "incentiveTokensTotal should be zeroed after recovery");
    }

    /// @notice Test that recovery fails when bids earned time
    function test_recoverIncentives_FailsWhenTimeEarned() public {
        // Create auction with a very high minAcceptableTick (restrictive price floor)
        // This means only very high price bids would be acceptable
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: 0, // High price floor - only tick >= 0 acceptable
            minAcceptableTickToken1: 0,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
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

        // Place a bid at tick 0 (exactly at minAcceptableTick)
        // This should be just at the acceptable limit
        _addBid(alice, 0, 1_000 ether);

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        assertGt(auction.cachedTotalWeightedTimeX128(), 0);
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.IncentivesStillClaimable.selector);
        auction.recoverIncentives(creator);
    }

    /// @notice Test recovery emits the IncentivesRecovered event
    function test_recoverIncentives_EmitsEvent() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        uint256 expectedAmount = auction.incentiveTokensTotal();

        vm.expectEmit(true, true, false, true);
        emit IOpeningAuction.IncentivesRecovered(creator, expectedAmount);

        vm.prank(creator);
        auction.recoverIncentives(creator);
    }

    /// @notice Test recovery can send to a different recipient
    function test_recoverIncentives_CanSendToDifferentRecipient() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        address recipient = address(0xbeef);
        uint256 expectedIncentives = auction.incentiveTokensTotal();

        vm.prank(creator);
        auction.recoverIncentives(recipient);

        assertEq(TestERC20(asset).balanceOf(recipient), expectedIncentives, "Recipient should receive tokens");
    }

    function test_sweepUnclaimedIncentives_AfterDeadline() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        int24 bidTick = minAcceptableTick + tickSpacing * 10;
        uint256 alicePos = _addBid(alice, bidTick, 50_000 ether);
        uint256 bobPos = _addBid(bob, bidTick + tickSpacing, 50_000 ether);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        vm.prank(alice);
        auction.claimIncentives(alicePos);

        vm.warp(auction.incentivesClaimDeadline() + 1);

        uint256 creatorBalanceBefore = TestERC20(asset).balanceOf(creator);
        vm.prank(creator);
        auction.sweepUnclaimedIncentives(creator);
        uint256 creatorBalanceAfter = TestERC20(asset).balanceOf(creator);

        assertGt(creatorBalanceAfter - creatorBalanceBefore, 0);

        vm.prank(bob);
        vm.expectRevert(IOpeningAuction.ClaimWindowEnded.selector);
        auction.claimIncentives(bobPos);
    }

    function test_sweepUnclaimedIncentives_RevertsBeforeDeadline() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        int24 bidTick = minAcceptableTick + tickSpacing * 10;
        _addBid(alice, bidTick, 50_000 ether);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.ClaimWindowNotEnded.selector);
        auction.sweepUnclaimedIncentives(creator);
    }

    function test_sweepUnclaimedIncentives_RevertsWhenNothingToSweep() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 0;
        auction = _createAuction(config);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        vm.warp(auction.incentivesClaimDeadline() + 1);

        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.NoUnclaimedIncentives.selector);
        auction.sweepUnclaimedIncentives(creator);
    }

    function test_sweepUnclaimedIncentives_RevertsOnSecondSweep() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        int24 bidTick = minAcceptableTick + tickSpacing * 10;
        uint256 alicePos = _addBid(alice, bidTick, 50_000 ether);
        _addBid(bob, bidTick + tickSpacing, 50_000 ether);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        vm.prank(alice);
        auction.claimIncentives(alicePos);

        vm.warp(auction.incentivesClaimDeadline() + 1);

        vm.prank(creator);
        auction.sweepUnclaimedIncentives(creator);

        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.NoUnclaimedIncentives.selector);
        auction.sweepUnclaimedIncentives(creator);
    }

    // ============ Recovery Failure Scenarios ============

    /// @notice Test that recovery fails when positions earned time but haven't claimed
    /// @dev When positions earn time, cachedTotalWeightedTimeX128 > 0 and recovery is blocked
    function test_recoverIncentives_RevertsWhenPositionsEarnedTime() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Place a bid at a high tick that will be in range
        // This position should earn time during the auction
        int24 highTick = 0;
        _addBid(alice, highTick, 50_000 ether);

        // Verify position is in range (would be filled)
        assertTrue(auction.isInRange(1), "Position should be in range");

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Settle auction
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Verify that time was accumulated
        assertGt(auction.cachedTotalWeightedTimeX128(), 0, "Weighted time should be accumulated");

        // Recovery should fail because positions earned time
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.IncentivesStillClaimable.selector);
        auction.recoverIncentives(creator);
    }

    /// @notice Test that recovery fails when some positions have claimed but others haven't
    /// @dev Even if one position claims, if another has unclaimed incentives, recovery is blocked
    ///      This test demonstrates that recovery is blocked based on cachedTotalWeightedTimeX128,
    ///      which is computed at settlement and does NOT change when positions claim.
    function test_recoverIncentives_RevertsWhenSomePositionsHaveNotClaimed() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Place a single position that will be in range
        // The key insight is that once ANY position earns time, cachedTotalWeightedTimeX128 > 0
        // and recovery is permanently blocked - even after all positions claim
        int24 highTick = 0;
        uint256 alicePos = _addBid(alice, highTick, 50_000 ether);

        // Verify position is in range (will earn time)
        assertTrue(auction.isInRange(alicePos), "Alice position should be in range");

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Settle auction
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Verify position earned time and has incentives
        assertGt(auction.cachedTotalWeightedTimeX128(), 0, "Weighted time should be accumulated");
        uint256 aliceIncentives = auction.calculateIncentives(alicePos);
        assertGt(aliceIncentives, 0, "Alice should have incentives");

        // Alice claims her incentives
        vm.prank(alice);
        auction.claimIncentives(alicePos);

        // Verify claim succeeded
        AuctionPosition memory pos = auction.positions(alicePos);
        assertTrue(pos.hasClaimedIncentives, "Alice should have claimed");

        // Recovery should STILL fail even though Alice has claimed
        // This is because cachedTotalWeightedTimeX128 > 0 is set at settlement and never changes
        // This is by design - it prevents any gaming of the recovery mechanism
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.IncentivesStillClaimable.selector);
        auction.recoverIncentives(creator);
    }

    /// @notice Test that recovery fails when not called by initializer
    function test_recoverIncentives_RevertsWhenNotInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Non-initializer tries to recover
        vm.prank(alice);
        vm.expectRevert(IOpeningAuction.SenderNotInitializer.selector);
        auction.recoverIncentives(alice);
    }

    /// @notice Test that recovery fails before auction is settled
    function test_recoverIncentives_RevertsBeforeSettlement() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Try to recover before auction ends
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.AuctionNotSettled.selector);
        auction.recoverIncentives(creator);

        // Warp to auction end but don't settle
        vm.warp(auction.auctionEndTime() + 1);

        // Still should fail
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.AuctionNotSettled.selector);
        auction.recoverIncentives(creator);
    }

    /// @notice Test that recovery fails on second attempt (double recovery prevention)
    function test_recoverIncentives_RevertsOnDoubleRecovery() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // First recovery succeeds
        vm.prank(creator);
        auction.recoverIncentives(creator);

        // Second recovery fails
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.NoIncentivesToRecover.selector);
        auction.recoverIncentives(creator);
    }

    /// @notice Test that recovery fails when incentiveShareBps is 0 (no incentives allocated)
    function test_recoverIncentives_RevertsWhenNoIncentivesAllocated() public {
        // Create auction with 0 incentive share
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minAcceptableTick,
            minAcceptableTickToken1: minAcceptableTick,
            incentiveShareBps: 0, // No incentives
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        (bytes32 salt,) = mineHookSalt(
            address(auctionDeployer),
            creator,
            AUCTION_TOKENS,
            config
        );

        vm.startPrank(creator);
        auction = auctionDeployer.deploy(
            AUCTION_TOKENS,
            salt,
            abi.encode(config)
        );

        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);
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

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Verify no incentives to recover
        assertEq(auction.incentiveTokensTotal(), 0, "Should have no incentive tokens");

        // Recovery should fail
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.NoIncentivesToRecover.selector);
        auction.recoverIncentives(creator);
    }

    // ============ Dust Behavior Documentation ============

    /// @notice Verify that dust remains locked after all positions claim
    /// @dev Due to rounding in MasterChef-style accounting, the sum of individual
    ///      incentive claims may be slightly less than incentiveTokensTotal.
    ///      This is expected behavior and the dust remains in the contract.
    function test_dust_RemainsLockedAfterAllClaims() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Place multiple bids to create potential for rounding dust
        int24 tick1 = 0;
        int24 tick2 = -60;
        int24 tick3 = -120;

        // Use slightly different liquidity amounts to maximize rounding scenarios
        uint256 pos1 = _addBid(alice, tick1, 33_333 ether);
        uint256 pos2 = _addBid(bob, tick2, 33_334 ether);
        uint256 pos3 = _addBid(alice, tick3, 33_333 ether);

        // Warp to auction end
        vm.warp(auction.auctionEndTime() + 1);

        // Settle auction
        auction.settleAuction();

        vm.prank(creator);
        auction.migrate(address(this));

        // Record total incentive tokens available
        uint256 totalIncentives = auction.incentiveTokensTotal();
        assertGt(totalIncentives, 0, "Should have incentive tokens");

        // Calculate incentives for all positions
        uint256 incentives1 = auction.calculateIncentives(pos1);
        uint256 incentives2 = auction.calculateIncentives(pos2);
        uint256 incentives3 = auction.calculateIncentives(pos3);

        uint256 totalClaimable = incentives1 + incentives2 + incentives3;

        console2.log("=== Dust Analysis ===");
        console2.log("Total incentive tokens:", totalIncentives);
        console2.log("Position 1 incentives:", incentives1);
        console2.log("Position 2 incentives:", incentives2);
        console2.log("Position 3 incentives:", incentives3);
        console2.log("Total claimable:", totalClaimable);
        console2.log("Potential dust:", totalIncentives - totalClaimable);

        // Claim all incentives
        vm.prank(alice);
        auction.claimIncentives(pos1);

        vm.prank(bob);
        auction.claimIncentives(pos2);

        vm.prank(alice);
        auction.claimIncentives(pos3);

        // Check hook's remaining asset balance
        uint256 hookBalance = TestERC20(asset).balanceOf(address(auction));

        // Due to rounding, there may be dust left over
        // This documents the expected behavior: dust is NOT recoverable
        // because cachedTotalWeightedTimeX128 > 0 after positions earned time
        console2.log("Hook balance after all claims:", hookBalance);

        // The dust amount should be very small (typically < total positions worth of rounding)
        // With 3 positions and Q128 math, dust should be negligible
        if (hookBalance > 0) {
            console2.log("Dust amount:", hookBalance);
            // Dust should be less than 1 wei per position in most cases, but can be higher
            // due to accumulated rounding across the Q128 division
            assertTrue(hookBalance < totalIncentives, "Dust should be much less than total");
        }

        // IMPORTANT: Even after all claims, recovery should still fail
        // because cachedTotalWeightedTimeX128 > 0
        vm.prank(creator);
        vm.expectRevert(IOpeningAuction.IncentivesStillClaimable.selector);
        auction.recoverIncentives(creator);

        // This documents the design decision: dust remains locked forever
        // rather than allowing recovery which could enable gaming the system
    }

    /// @notice Test that incentive amounts sum to approximately (but not exactly) total
    /// @dev Documents the rounding behavior inherent in MasterChef-style accounting
    function test_dust_IncentiveSumApproximatesTotal() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        auction = _createAuction(config);

        // Create a more complex scenario with many positions
        int24 baseTick = 0;
        uint256[] memory positions = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            int24 tick = baseTick - int24(int256(i * 60));
            address bidder = i % 2 == 0 ? alice : bob;
            positions[i] = _addBid(bidder, tick, uint128(10_000 ether + i * 1_000 ether));
        }

        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        uint256 totalIncentives = auction.incentiveTokensTotal();
        uint256 sumClaimable = 0;

        for (uint256 i = 0; i < 5; i++) {
            sumClaimable += auction.calculateIncentives(positions[i]);
        }

        console2.log("=== Incentive Sum Analysis ===");
        console2.log("Total incentive tokens:", totalIncentives);
        console2.log("Sum of claimable:", sumClaimable);
        console2.log("Difference (dust):", totalIncentives - sumClaimable);
        console2.log("Difference as % of total:", (totalIncentives - sumClaimable) * 10000 / totalIncentives, "basis points");

        // Sum should be very close to total (within 0.01% due to rounding)
        assertApproxEqRel(sumClaimable, totalIncentives, 0.0001e18, "Sum should approximate total within 0.01%");

        // Sum should never exceed total (no inflation)
        assertLe(sumClaimable, totalIncentives, "Sum should never exceed total");
    }
}
