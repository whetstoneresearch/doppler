// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
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
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @title OpeningAuctionConcurrentTest
/// @notice Tests for multiple concurrent auctions running simultaneously
contract OpeningAuctionConcurrentTest is Test, Deployers {
    // Multiple token pairs
    address constant TOKEN_A = address(0x1111);
    address constant TOKEN_B = address(0x2222);
    address constant TOKEN_C = address(0x3333);
    address constant TOKEN_D = address(0x4444);
    address constant NUMERAIRE = address(0x9999);

    // Users
    address creator = address(0xc4ea70);
    address alice = address(0xa71c3);
    address bob = address(0xb0b);

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 100e18;
    uint256 constant AUCTION_DURATION = 1 days;

    // Multiple auctions
    OpeningAuctionImpl[] hooks;
    PoolKey[] poolKeys;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_B);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_C);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), TOKEN_D);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint128).max), NUMERAIRE);

        vm.label(TOKEN_A, "TokenA");
        vm.label(TOKEN_B, "TokenB");
        vm.label(TOKEN_C, "TokenC");
        vm.label(TOKEN_D, "TokenD");
        vm.label(NUMERAIRE, "Numeraire");

        // Deploy router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Fund users
        address[5] memory tokens = [TOKEN_A, TOKEN_B, TOKEN_C, TOKEN_D, NUMERAIRE];
        for (uint256 i = 0; i < tokens.length; i++) {
            TestERC20(tokens[i]).transfer(creator, 10 * AUCTION_TOKENS);
            TestERC20(tokens[i]).transfer(alice, 10_000_000 ether);
            TestERC20(tokens[i]).transfer(bob, 10_000_000 ether);
        }
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
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        int24 minTick = alignTickTowardZero(TickMath.MIN_TICK, 60);
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: minTick,
            minAcceptableTickToken1: minTick,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15
        });
    }

    function _deployAuction(
        address asset,
        uint256 hookSalt
    ) internal returns (OpeningAuctionImpl hook, PoolKey memory poolKey) {
        OpeningAuctionConfig memory config = getDefaultConfig();

        (address token0, address token1) = asset < NUMERAIRE ? (asset, NUMERAIRE) : (NUMERAIRE, asset);
        bool isToken0 = asset < NUMERAIRE;

        address hookAddress = address(uint160(uint256(keccak256(abi.encode(asset, hookSalt))) | getHookFlags()));

        deployCodeTo(
            "OpeningAuctionConcurrent.t.sol:OpeningAuctionImpl",
            abi.encode(manager, creator, AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionImpl(payable(hookAddress));

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
        hook.setIsToken0(isToken0);
        int24 startingTick = alignTickTowardZero(
            isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK,
            config.tickSpacing
        );
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();
    }

    function _addBid(
        OpeningAuctionImpl hook,
        PoolKey memory poolKey,
        address bidder,
        int24 tickLower,
        uint128 liquidity
    ) internal returns (uint256 positionId) {
        vm.startPrank(bidder);
        TestERC20(Currency.unwrap(poolKey.currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(Currency.unwrap(poolKey.currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        positionId = hook.nextPositionId();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(positionId)
            }),
            abi.encode(bidder)
        );
        vm.stopPrank();
    }

    /// @notice Test two concurrent auctions for different assets
    function test_concurrent_TwoAuctions() public {
        // Deploy two auctions
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x7777);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x8888);

        OpeningAuctionConfig memory config = getDefaultConfig();

        // Alice bids on both - need enough liquidity at high ticks for settlement
        int24 baseTick = 0;
        uint128 liquidityPerBid = 1_000_000 ether;
        for (uint256 i = 0; i < 40; i++) {
            _addBid(hook1, key1, alice, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
        }
        for (uint256 i = 0; i < 40; i++) {
            _addBid(hook2, key2, alice, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
        }

        // Bob bids only on first
        for (uint256 i = 0; i < 20; i++) {
            _addBid(hook1, key1, bob, baseTick - config.tickSpacing * int24(int256(60 + i)), liquidityPerBid);
        }

        // Warp and settle both
        vm.warp(hook1.auctionEndTime() + 1);

        hook1.settleAuction();
        hook2.settleAuction();

        // Verify both settled independently
        assertEq(uint8(hook1.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook2.phase()), uint8(AuctionPhase.Settled));

        // Clearing ticks can be different
        emit log_named_int("Auction 1 clearing tick", hook1.clearingTick());
        emit log_named_int("Auction 2 clearing tick", hook2.clearingTick());
    }

    /// @notice Test four concurrent auctions
    function test_concurrent_FourAuctions() public {
        // Deploy four auctions
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x1001);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x1002);
        (OpeningAuctionImpl hook3, PoolKey memory key3) = _deployAuction(TOKEN_C, 0x1003);
        (OpeningAuctionImpl hook4, PoolKey memory key4) = _deployAuction(TOKEN_D, 0x1004);

        OpeningAuctionConfig memory config = getDefaultConfig();

        // Bidders participate in multiple auctions - need many bids with high liquidity
        int24 baseTick = 0;
        uint128 liquidityPerBid = 1_000_000 ether;
        for (uint256 i = 0; i < 40; i++) {
            _addBid(hook1, key1, alice, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
            _addBid(hook2, key2, alice, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
            _addBid(hook3, key3, bob, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
            _addBid(hook4, key4, bob, baseTick - config.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
        }

        // Cross-participation
        for (uint256 i = 0; i < 20; i++) {
            _addBid(hook1, key1, bob, baseTick - config.tickSpacing * int24(int256(60 + i)), liquidityPerBid);
            _addBid(hook3, key3, alice, baseTick - config.tickSpacing * int24(int256(60 + i)), liquidityPerBid);
        }

        // Warp and settle all
        vm.warp(hook1.auctionEndTime() + 1);

        hook1.settleAuction();
        hook2.settleAuction();
        hook3.settleAuction();
        hook4.settleAuction();

        // All should settle
        assertEq(uint8(hook1.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook2.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook3.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook4.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test staggered auction starts and ends
    function test_concurrent_StaggeredTimings() public {
        OpeningAuctionConfig memory config1 = getDefaultConfig();
        OpeningAuctionConfig memory config2 = getDefaultConfig();
        config2.auctionDuration = 2 days; // Longer auction

        // Deploy first auction
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x2001);

        // Warp 12 hours and deploy second auction
        vm.warp(block.timestamp + 12 hours);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x2002);

        // Add bids to both - need enough liquidity
        int24 baseTick = 0;
        uint128 liquidityPerBid = 1_000_000 ether;
        for (uint256 i = 0; i < 60; i++) {
            _addBid(hook1, key1, alice, baseTick - config1.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
            _addBid(hook2, key2, alice, baseTick - config2.tickSpacing * int24(int256(20 + i)), liquidityPerBid);
        }

        // First auction ends first
        vm.warp(hook1.auctionEndTime() + 1);
        assertEq(uint8(hook1.phase()), uint8(AuctionPhase.Active));
        assertEq(uint8(hook2.phase()), uint8(AuctionPhase.Active)); // Still active

        // Settle first
        hook1.settleAuction();
        assertEq(uint8(hook1.phase()), uint8(AuctionPhase.Settled));

        // Add more bids to second (still active)
        _addBid(hook2, key2, bob, baseTick - config2.tickSpacing * 25, 1_500_000 ether);

        // Second auction ends
        vm.warp(hook2.auctionEndTime() + 1);
        hook2.settleAuction();
        assertEq(uint8(hook2.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test that auctions don't interfere with each other's incentives
    function test_concurrent_IndependentIncentives() public {
        // Deploy two auctions
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x3001);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x3002);

        OpeningAuctionConfig memory config = getDefaultConfig();

        // Alice bids on auction 1 with more liquidity
        uint256 alicePos1 = _addBid(hook1, key1, alice, 0, 1_000_000 ether);

        // Bob bids on auction 2 with less liquidity
        uint256 bobPos2 = _addBid(hook2, key2, bob, 0, 200_000 ether);

        // Both warp through auction period
        vm.warp(hook1.auctionEndTime() + 1);

        // Settle both
        hook1.settleAuction();
        hook2.settleAuction();

        vm.startPrank(creator);
        hook1.migrate(address(this));
        hook2.migrate(address(this));
        vm.stopPrank();

        // Claim incentives - get balances before/after since claimIncentives returns void
        uint256 aliceBalBefore = TestERC20(TOKEN_A).balanceOf(alice);
        vm.prank(alice);
        hook1.claimIncentives(alicePos1);
        uint256 aliceIncentives = TestERC20(TOKEN_A).balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = TestERC20(TOKEN_B).balanceOf(bob);
        vm.prank(bob);
        hook2.claimIncentives(bobPos2);
        uint256 bobIncentives = TestERC20(TOKEN_B).balanceOf(bob) - bobBalBefore;

        emit log_named_uint("Alice incentives from auction 1", aliceIncentives);
        emit log_named_uint("Bob incentives from auction 2", bobIncentives);

        // Both should have non-zero incentives
        assertGt(aliceIncentives, 0);
        assertGt(bobIncentives, 0);

        // Incentives are independent - each gets their auction's allocation
        uint256 auction1Incentives = (AUCTION_TOKENS * config.incentiveShareBps) / 10_000;
        uint256 auction2Incentives = (AUCTION_TOKENS * config.incentiveShareBps) / 10_000;

        assertLe(aliceIncentives, auction1Incentives);
        assertLe(bobIncentives, auction2Incentives);
    }

    /// @notice Test same user bidding on multiple auctions and claiming from all
    function test_concurrent_MultiAuctionClaims() public {
        // Deploy three auctions
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x4001);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x4002);
        (OpeningAuctionImpl hook3, PoolKey memory key3) = _deployAuction(TOKEN_C, 0x4003);

        // Alice bids on all three
        uint256 pos1 = _addBid(hook1, key1, alice, 0, 1_000_000 ether);
        uint256 pos2 = _addBid(hook2, key2, alice, 0, 1_000_000 ether);
        uint256 pos3 = _addBid(hook3, key3, alice, 0, 1_000_000 ether);

        // Warp and settle all
        vm.warp(hook1.auctionEndTime() + 1);

        hook1.settleAuction();
        hook2.settleAuction();
        hook3.settleAuction();

        vm.startPrank(creator);
        hook1.migrate(address(this));
        hook2.migrate(address(this));
        hook3.migrate(address(this));
        vm.stopPrank();

        // Alice claims from all three - track balances before/after
        uint256 balA_before = TestERC20(TOKEN_A).balanceOf(alice);
        uint256 balB_before = TestERC20(TOKEN_B).balanceOf(alice);
        uint256 balC_before = TestERC20(TOKEN_C).balanceOf(alice);

        vm.startPrank(alice);
        hook1.claimIncentives(pos1);
        hook2.claimIncentives(pos2);
        hook3.claimIncentives(pos3);
        vm.stopPrank();

        uint256 claim1 = TestERC20(TOKEN_A).balanceOf(alice) - balA_before;
        uint256 claim2 = TestERC20(TOKEN_B).balanceOf(alice) - balB_before;
        uint256 claim3 = TestERC20(TOKEN_C).balanceOf(alice) - balC_before;

        emit log_named_uint("Alice claim from auction 1", claim1);
        emit log_named_uint("Alice claim from auction 2", claim2);
        emit log_named_uint("Alice claim from auction 3", claim3);

        // All claims should be non-zero
        assertGt(claim1, 0);
        assertGt(claim2, 0);
        assertGt(claim3, 0);
    }

    /// @notice Test settling auctions in different orders
    function test_concurrent_SettlementOrder() public {
        // Deploy three auctions at same time
        (OpeningAuctionImpl hook1, PoolKey memory key1) = _deployAuction(TOKEN_A, 0x5001);
        (OpeningAuctionImpl hook2, PoolKey memory key2) = _deployAuction(TOKEN_B, 0x5002);
        (OpeningAuctionImpl hook3, PoolKey memory key3) = _deployAuction(TOKEN_C, 0x5003);

        OpeningAuctionConfig memory config = getDefaultConfig();

        // Add bids
        int24 baseTick = 0;
        _addBid(hook1, key1, alice, baseTick - config.tickSpacing * 20, 1_000_000 ether);
        _addBid(hook2, key2, alice, baseTick - config.tickSpacing * 30, 1_000_000 ether);
        _addBid(hook3, key3, alice, baseTick - config.tickSpacing * 40, 1_000_000 ether);

        // Warp past all end times
        vm.warp(hook1.auctionEndTime() + 1);

        // Settle in reverse order (3, 2, 1)
        hook3.settleAuction();
        hook2.settleAuction();
        hook1.settleAuction();

        // All should settle regardless of order
        assertEq(uint8(hook1.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook2.phase()), uint8(AuctionPhase.Settled));
        assertEq(uint8(hook3.phase()), uint8(AuctionPhase.Settled));
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
