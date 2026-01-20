// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @title OpeningAuctionAttacksTest
/// @notice Security tests for flash loan attacks and MEV sandwich attacks
contract OpeningAuctionAttacksTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;
    address token0;
    address token1;

    // Users
    address creator = address(0xc4ea70);
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address attacker = address(0xbad);
    uint256 bidNonce;
    mapping(uint256 => bytes32) internal positionSalts;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 1000 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    OpeningAuctionImpl hook;
    PoolKey poolKey;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // Fund users
        TestERC20(token0).transfer(alice, 10_000_000 ether);
        TestERC20(token1).transfer(alice, 10_000_000 ether);
        TestERC20(token0).transfer(bob, 10_000_000 ether);
        TestERC20(token1).transfer(bob, 10_000_000 ether);
        TestERC20(token0).transfer(attacker, 100_000_000 ether);
        TestERC20(token1).transfer(attacker, 100_000_000 ether);
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

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -34_020,
            minAcceptableTickToken1: -34_020,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });
    }

    function _deployAuction(OpeningAuctionConfig memory config) internal {
        address hookAddress = address(uint160(getHookFlags()) ^ (0x6666 << 144));

        deployCodeTo(
            "OpeningAuctionAttacks.t.sol:OpeningAuctionImpl",
            abi.encode(manager, creator, AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionImpl(payable(hookAddress));
        vm.label(address(hook), "OpeningAuction");

        vm.prank(creator);
        TestERC20(asset).transfer(address(hook), AUCTION_TOKENS);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(creator);
        hook.setIsToken0(true);
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();
    }

    function _addBid(address bidder, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        vm.startPrank(bidder);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        bytes32 salt = keccak256(abi.encode(bidder, bidNonce++));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(bidder)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(bidder, tickLower, tickLower + poolKey.tickSpacing, salt);
        positionSalts[positionId] = salt;
    }

    // ============ Flash Loan Attack Tests ============

    /// @notice Test that flash loan cannot manipulate clearing price by adding and removing large bid
    function test_attack_FlashLoanBidManipulation() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        _deployAuction(config);

        // Normal bidders place bids with enough liquidity to settle
        for (uint256 i = 0; i < 50; i++) {
            address bidder = i % 2 == 0 ? alice : bob;
            _addBid(bidder, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 100e18);
        }

        // Get estimated clearing tick before attack
        vm.warp(hook.auctionEndTime() - 100);
        int24 estimateBefore = hook.estimatedClearingTick();

        // Attacker simulates flash loan - adds massive bid at/near clearing tick
        int24 attackerTickLower = alignTickTowardZero(estimateBefore, config.tickSpacing);
        if (attackerTickLower < config.minAcceptableTickToken0) {
            attackerTickLower = config.minAcceptableTickToken0;
        }
        uint256 attackerPosId = _addBid(attacker, attackerTickLower, 1_000_000 ether);

        AuctionPosition memory pos = hook.positions(attackerPosId);
        bool isLocked = hook.isPositionLocked(attackerPosId);
        assertTrue(isLocked, "Attacker position should be locked near clearing tick");

        // Attacker tries to remove bid in same block (should revert)
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.PositionIsLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: attackerTickLower,
                tickUpper: attackerTickLower + config.tickSpacing,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: positionSalts[attackerPosId]
            }),
            abi.encode(attacker)
        );
        vm.stopPrank();

        assertEq(hook.positions(attackerPosId).liquidity, pos.liquidity, "Locked position should remain");

        // Warp to auction end and settle
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        // Auction should settle successfully with reasonable clearing tick
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
        assertGe(hook.clearingTick(), config.minAcceptableTickToken0);
    }

    /// @notice Test that flash loan cannot steal incentive tokens
    function test_attack_FlashLoanIncentiveTheft() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        _deployAuction(config);

        // Normal bidders place bids early with enough liquidity to settle
        uint256 alicePosId;
        for (uint256 i = 0; i < 50; i++) {
            uint256 posId =
                _addBid(alice, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 100e18);
            if (i == 0) {
                alicePosId = posId;
            }
        }

        // Warp through most of auction
        vm.warp(hook.auctionEndTime() - 10);

        // Attacker adds large bid right at the end to try to claim most incentives
        uint256 attackerPosId = _addBid(attacker, config.minAcceptableTickToken0 + config.tickSpacing * 10, 500_000 ether);

        // Warp and settle
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        vm.prank(creator);
        hook.migrate(address(this));

        // Get incentive token (asset token) balance before claims
        // Asset is token0 if isToken0 is true, otherwise token1
        address incentiveToken = hook.isToken0() ? address(token0) : address(token1);
        uint256 aliceBalBefore = IERC20(incentiveToken).balanceOf(alice);
        uint256 attackerBalBefore = IERC20(incentiveToken).balanceOf(attacker);

        // Claim incentives
        vm.prank(alice);
        hook.claimIncentives(alicePosId);

        vm.prank(attacker);
        hook.claimIncentives(attackerPosId);

        uint256 aliceIncentives = IERC20(incentiveToken).balanceOf(alice) - aliceBalBefore;
        uint256 attackerIncentives = IERC20(incentiveToken).balanceOf(attacker) - attackerBalBefore;

        emit log_named_uint("Alice incentives (early bid)", aliceIncentives);
        emit log_named_uint("Attacker incentives (last second)", attackerIncentives);

        uint256 aliceTime = hook.getPositionAccumulatedTime(alicePosId);
        uint256 attackerTime = hook.getPositionAccumulatedTime(attackerPosId);

        assertGt(aliceTime, attackerTime, "Early bidder should accrue more time than late attacker");
        assertGt(aliceIncentives, attackerIncentives, "Incentives should follow time weight");
        assertLe(aliceIncentives + attackerIncentives, hook.incentiveTokensTotal(), "Incentives should not exceed pool");
    }

    /// @notice Test protection against flash loan used to avoid position locking
    function test_attack_FlashLoanAvoidLocking() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        _deployAuction(config);

        // Add many initial bids with enough liquidity at higher ticks
        for (uint256 i = 0; i < 75; i++) {
            _addBid(alice, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 150e18);
        }

        // Attacker adds bid near estimated clearing range
        vm.warp(hook.auctionEndTime() - 3600); // 1 hour before end
        int24 nearClearingTick = 0;
        uint256 attackerPosId = _addBid(attacker, nearClearingTick, 100e18);

        // Check if position is locked
        AuctionPosition memory pos = hook.positions(attackerPosId);
        bool isLocked = hook.isPositionLocked(attackerPosId);
        assertTrue(isLocked, "Position should be locked near clearing range");

        // Attacker cannot remove locked position
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.PositionIsLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: nearClearingTick,
                tickUpper: nearClearingTick + config.tickSpacing,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: positionSalts[attackerPosId]
            }),
            abi.encode(attacker)
        );
        vm.stopPrank();

        // Warp and settle
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    // ============ MEV Sandwich Attack Tests ============

    /// @notice Test that settlement cannot be manipulated by sandwich attack
    function test_attack_SettlementSandwich() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        _deployAuction(config);

        // Normal bidders with enough liquidity
        for (uint256 i = 0; i < 50; i++) {
            address bidder = i % 2 == 0 ? alice : bob;
            _addBid(bidder, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 100e18);
        }

        vm.warp(hook.auctionEndTime() + 1);

        // Get expected clearing tick before settlement
        int24 expectedClearingTick = hook.estimatedClearingTick();

        // Attacker tries to frontrun settlement by adding bid
        // (This should not affect clearing since auction is closed)
        vm.startPrank(attacker);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        bytes32 attackerSalt = keccak256(abi.encode(attacker, bidNonce++));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.BiddingClosed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: config.tickSpacing,
                liquidityDelta: int256(uint256(1_000_000 ether)),
                salt: attackerSalt
            }),
            abi.encode(attacker)
        );
        vm.stopPrank();

        // Settlement proceeds normally
        hook.settleAuction();

        // Clearing tick should be as expected (no manipulation)
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
        int24 actualClearingTick = hook.clearingTick();
        int24 diff = expectedClearingTick > actualClearingTick
            ? expectedClearingTick - actualClearingTick
            : actualClearingTick - expectedClearingTick;
        assertLe(diff, config.tickSpacing, "Clearing tick should match pre-settlement estimate");
        emit log_named_int("Expected clearing tick", expectedClearingTick);
        emit log_named_int("Actual clearing tick", actualClearingTick);
    }

    /// @notice Test that minAcceptableTick prevents price manipulation attacks
    function test_attack_PriceManipulationBelowMinTick() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = -20_000; // Higher min acceptable tick
        // Align minAcceptableTick to tickSpacing
        config.minAcceptableTickToken0 = (config.minAcceptableTickToken0 / config.tickSpacing) * config.tickSpacing;
        _deployAuction(config);

        // Attacker places only low-price bids to try to get tokens cheap
        // Place bid at a valid tick that's still below minAcceptableTick
        int24 lowTick = config.minAcceptableTickToken0 - config.tickSpacing * 10;
        vm.startPrank(attacker);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        bytes32 attackerSalt = keccak256(abi.encode(attacker, bidNonce++));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.BidBelowMinimumPrice.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowTick,
                tickUpper: lowTick + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(1_000_000e18)),
                salt: attackerSalt
            }),
            abi.encode(attacker)
        );
        vm.stopPrank();

        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
        assertGe(hook.clearingTick(), config.minAcceptableTickToken0);
    }

    /// @notice Test that late large bid doesn't disproportionately affect outcome
    function test_attack_LastBlockManipulation() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        _deployAuction(config);

        // Normal bidders with enough liquidity throughout auction
        for (uint256 i = 0; i < 50; i++) {
            _addBid(alice, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 200e18);
        }

        vm.warp(hook.auctionEndTime() / 2);
        for (uint256 i = 0; i < 30; i++) {
            _addBid(bob, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(60 + i)), 200e18);
        }

        // Get clearing tick estimate mid-auction
        int24 midAuctionEstimate = hook.estimatedClearingTick();

        // Last second massive bid from attacker at high price
        vm.warp(hook.auctionEndTime() - 1);
        _addBid(attacker, config.minAcceptableTickToken0 + config.tickSpacing * 100, 10_000 ether);

        int24 finalEstimate = hook.estimatedClearingTick();

        emit log_named_int("Mid-auction clearing estimate", midAuctionEstimate);
        emit log_named_int("Final clearing estimate (after attack)", finalEstimate);

        // Settle and verify
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        // The attacker's bid is legitimate - they just bought at a high price
        // This tests that the mechanism handles it correctly
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
        assertGt(hook.totalTokensSold(), 0);
        int24 finalClearingTick = hook.clearingTick();
        int24 diff = finalEstimate > finalClearingTick
            ? finalEstimate - finalClearingTick
            : finalClearingTick - finalEstimate;
        assertLe(diff, config.tickSpacing, "Final estimate should match settlement result");
    }

    /// @notice Test reentrancy protection on settlement
    function test_attack_SettlementReentrancy() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        _deployAuction(config);

        _addBid(alice, config.minAcceptableTickToken0 + config.tickSpacing * 30, 100_000 ether);

        vm.warp(hook.auctionEndTime() + 1);

        // First settlement
        hook.settleAuction();

        // Second settlement should fail
        vm.expectRevert(IOpeningAuction.AuctionNotActive.selector);
        hook.settleAuction();
    }

    /// @notice Test that attacker cannot manipulate TOCTOU between quote and settlement
    function test_attack_TOCTOUManipulation() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = alignTickTowardZero(TickMath.MIN_TICK, config.tickSpacing);
        _deployAuction(config);

        // Add bids with enough liquidity
        for (uint256 i = 0; i < 75; i++) {
            address bidder = i % 2 == 0 ? alice : bob;
            _addBid(bidder, config.minAcceptableTickToken0 + config.tickSpacing * int24(int256(10 + i)), 200e18);
        }

        vm.warp(hook.auctionEndTime() + 1);

        // Get quote
        int24 quotedClearingTick = hook.estimatedClearingTick();

        // Settlement uses minAcceptableTick as price limit to prevent TOCTOU
        // Even if somehow the pool state changed between quote and swap,
        // the minAcceptableTick check in unlockCallback prevents bad settlements
        hook.settleAuction();

        // Verify settlement occurred at or above min acceptable tick
        assertGe(hook.clearingTick(), config.minAcceptableTickToken0);

        emit log_named_int("Quoted clearing tick", quotedClearingTick);
        emit log_named_int("Actual clearing tick", hook.clearingTick());
    }
}

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}
