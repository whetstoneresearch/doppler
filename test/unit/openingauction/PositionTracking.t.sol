// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { AuctionPosition, OpeningAuctionConfig, IOpeningAuction } from "src/interfaces/IOpeningAuction.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";

contract PositionTrackingTest is OpeningAuctionBaseTest {
    function setUp() public override {
        manager = new PoolManager(address(this));

        _deployTokens();

        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 10_000; // Ensure positions stay out of range for deterministic tests.
        _deployOpeningAuction(config, DEFAULT_AUCTION_TOKENS);

        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        TestERC20(token0).transfer(alice, 1_000_000 ether);
        TestERC20(token1).transfer(alice, 1_000_000 ether);
        TestERC20(token0).transfer(bob, 1_000_000 ether);
        TestERC20(token1).transfer(bob, 1_000_000 ether);
    }

    function test_afterAddLiquidity_TracksPositionCorrectly() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 amount = 1 ether;

        uint256 positionIdBefore = hook.nextPositionId();

        uint256 positionId = _addBid(alice, tickLower, amount);

        // Position ID should have incremented
        assertEq(hook.nextPositionId(), positionIdBefore + 1);

        // Get the position
        AuctionPosition memory pos = hook.positions(positionId);

        // With hook-owned liquidity, the owner is the actual user who called addBid()
        assertEq(pos.owner, alice);
        assertEq(pos.tickLower, tickLower);
        assertEq(pos.tickUpper, tickLower + key.tickSpacing);
        assertGt(pos.liquidity, 0);
    }

    function test_afterAddLiquidity_TracksMultiplePositions() public {
        int24 tickLower1 = hook.minAcceptableTick() + key.tickSpacing * 10;
        int24 tickLower2 = hook.minAcceptableTick() + key.tickSpacing * 20;

        uint256 posId1 = _addBid(alice, tickLower1, 1 ether);
        uint256 posId2 = _addBid(bob, tickLower2, 2 ether);

        AuctionPosition memory pos1 = hook.positions(posId1);
        AuctionPosition memory pos2 = hook.positions(posId2);

        // With hook-owned liquidity, each position is owned by the actual user
        assertEq(pos1.owner, alice);
        assertEq(pos1.tickLower, tickLower1);

        assertEq(pos2.owner, bob);
        assertEq(pos2.tickLower, tickLower2);
    }

    function test_afterAddLiquidity_EmitsBidPlacedEvent() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 amount = 1 ether;
        uint256 expectedPositionId = hook.nextPositionId();
        int24 tickUpper = tickLower + key.tickSpacing;
        bytes32 salt = keccak256(abi.encode(alice, bidNonce++));

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit IOpeningAuction.BidPlaced(expectedPositionId, alice, tickLower, amount);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)),
                salt: salt
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 positionId = hook.getPositionId(alice, tickLower, tickUpper, salt);
        assertEq(positionId, expectedPositionId);

        // Verify position was created with correct owner
        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.owner, alice);
    }

    function test_position_InitiallyNotLocked_WhenOutOfRange() public {
        // Place a bid far from current tick (which is at MAX_TICK)
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, 1 ether);

        assertFalse(hook.isInRange(positionId), "Position should be out of range");
        assertFalse(hook.isPositionLocked(positionId), "Position should not be locked");
    }

    function test_position_HasZeroAccumulatedTimeInitially() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, 1 ether);

        assertFalse(hook.isInRange(positionId), "Position should be out of range");
        uint256 accumulatedTime = hook.getPositionAccumulatedTime(positionId);
        assertEq(accumulatedTime, 0, "Out-of-range position should start at 0");
    }

    function test_position_HasNotClaimedIncentivesInitially() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;

        uint256 positionId = _addBid(alice, tickLower, 1 ether);

        AuctionPosition memory pos = hook.positions(positionId);

        assertFalse(pos.hasClaimedIncentives);
    }

    function test_afterAddLiquidity_RevertsOnSameSaltReuse() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 amount = hook.minLiquidity() * 10;
        bytes32 salt = keccak256("same-salt");

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(amount)),
                salt: salt
            }),
            abi.encode(alice)
        );

        bytes32 positionKey = keccak256(abi.encodePacked(alice, tickLower, tickLower + key.tickSpacing, salt));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterAddLiquidity.selector,
                abi.encodeWithSelector(IOpeningAuction.PositionAlreadyExists.selector, positionKey),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(amount)),
                salt: salt
            }),
            abi.encode(alice)
        );
        vm.stopPrank();
    }
}
