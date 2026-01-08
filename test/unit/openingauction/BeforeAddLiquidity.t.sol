// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";

contract BeforeAddLiquidityTest is OpeningAuctionBaseTest {
    function test_beforeAddLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(this),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000,
                tickUpper: -100_000 + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_beforeAddLiquidity_AllowsValidSingleTickPosition() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_RevertsNotSingleTickPosition() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        // Multi-tick position (2 ticks wide)
        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.NotSingleTickPosition.selector);
        hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing * 2, // 2 tick spacings
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_beforeAddLiquidity_RevertsBidBelowMinimumPrice() public {
        // minAcceptableTick is -99960
        // Placing a bid below that should revert
        int24 tickLower = hook.minAcceptableTick() - key.tickSpacing;

        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.BidBelowMinimumPrice.selector);
        hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_beforeAddLiquidity_AllowsBidAtMinimumPrice() public {
        int24 tickLower = hook.minAcceptableTick();

        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_AllowsBidAboveMinimumPrice() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing;

        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_RevertsAfterSettlement() public {
        // Warp to after auction end
        _warpToAuctionEnd();

        // Settle auction first to change phase
        hook.settleAuction();

        int24 tickLower = hook.minAcceptableTick();

        // After settlement, adding liquidity should be disallowed for safety.
        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.AuctionNotActive.selector);
        hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_beforeAddLiquidity_RevertsBiddingClosedAfterAuctionEnd() public {
        // Warp to after auction end but don't settle
        _warpToAuctionEnd();

        // Phase is still Active, but bidding should be closed
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Active));

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        // Attempting to add a bid after auction end should revert
        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.BiddingClosed.selector);
        hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_beforeAddLiquidity_AllowsBidJustBeforeAuctionEnd() public {
        // Warp to 1 second before auction end
        vm.warp(hook.auctionEndTime() - 1);

        // Phase is Active and we're still in the bidding window
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Active));

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        // Should still be allowed
        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            alice,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }
}
