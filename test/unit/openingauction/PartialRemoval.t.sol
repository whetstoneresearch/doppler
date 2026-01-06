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
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition, IOpeningAuction } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionPartialRemovalImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title PartialRemovalTest
/// @notice Tests for CRITICAL-2: Disallow partial liquidity removal to prevent incentive accounting corruption
/// @dev The bug was: partial removal didn't decrement pos.liquidity, allowing over-claiming of incentives
contract PartialRemovalTest is Test, Deployers {
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

    // Contracts
    OpeningAuctionPartialRemovalImpl auction;
    PoolKey poolKey;

    // Auction parameters
    uint256 constant AUCTION_TOKENS = 1000;
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
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function _createAuction() internal {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });

        address hookAddress = address(uint160(getHookFlags()) ^ (0x7777 << 144));

        deployCodeTo(
            "PartialRemoval.t.sol:OpeningAuctionPartialRemovalImpl",
            abi.encode(manager, creator, AUCTION_TOKENS, config),
            hookAddress
        );

        auction = OpeningAuctionPartialRemovalImpl(payable(hookAddress));
        vm.label(address(auction), "OpeningAuction");

        vm.prank(creator);
        TestERC20(asset).transfer(address(auction), AUCTION_TOKENS);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(auction))
        });

        vm.startPrank(creator);
        auction.setIsToken0(true);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));
        vm.stopPrank();
    }

    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + tickSpacing;
        positionId = auction.nextPositionId();

        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(positionId)
            }),
            abi.encode(user)
        );
        vm.stopPrank();
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
                salt: bytes32(positionId)
            }),
            abi.encode(user)
        );
        vm.stopPrank();
    }

    // ============ Tests: Full Removal Succeeds ============

    /// @notice Test that full removal of an out-of-range position succeeds
    function test_fullRemoval_OutOfRangePosition_Succeeds() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens (in-range)
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a lower bid (out-of-range because Alice absorbs all)
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 1000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Verify Bob is out of range
        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Full removal should succeed
        _removeBid(bob, bobTickLower, bobLiquidity, bobPos);

        // Verify position is gone (liquidity is 0)
        // Note: Position struct still exists but liquidity tracking should be updated
        assertEq(auction.liquidityAtTick(bobTickLower), 0, "Tick liquidity should be 0 after full removal");
    }

    // ============ Tests: Partial Removal Reverts ============

    /// @notice Test that partial removal reverts with PartialRemovalNotAllowed
    function test_partialRemoval_Reverts() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens (in-range)
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a lower bid (out-of-range)
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 1000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        // Verify Bob is out of range (should be removable if full removal)
        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Try to remove only HALF of Bob's liquidity (partial removal)
        uint128 partialLiquidity = bobLiquidity / 2;

        // Should revert (error gets wrapped by pool manager)
        vm.expectRevert();
        _removeBid(bob, bobTickLower, partialLiquidity, bobPos);
    }

    /// @notice Test that removing slightly less than full liquidity reverts
    function test_partialRemoval_SlightlyLess_Reverts() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a lower bid
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 1000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Try to remove liquidity - 1 (one wei less than full)
        uint128 almostFullLiquidity = bobLiquidity - 1;

        vm.expectRevert();
        _removeBid(bob, bobTickLower, almostFullLiquidity, bobPos);
    }

    /// @notice Test that removing slightly more than position liquidity reverts
    /// @dev This would fail anyway due to underflow, but good to test
    function test_partialRemoval_SlightlyMore_Reverts() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places a lower bid
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 1000 ether;
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Try to remove liquidity + 1 (one wei more than position has)
        uint128 tooMuchLiquidity = bobLiquidity + 1;

        vm.expectRevert();
        _removeBid(bob, bobTickLower, tooMuchLiquidity, bobPos);
    }

    // ============ Tests: In-Range Position Cannot Be Removed ============

    /// @notice Test that in-range positions still cannot be removed (even full removal)
    function test_inRangePosition_CannotBeRemoved_EvenFullRemoval() public {
        _createAuction();

        // Alice places a bid with enough liquidity to absorb all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Verify Alice is in range
        assertTrue(auction.isInRange(alicePos), "Alice should be in range");

        // Even full removal should revert (position is locked)
        vm.expectRevert();
        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);
    }

    // ============ Tests: After Settlement ============

    /// @notice Test that after settlement, positions can be fully removed
    function test_afterSettlement_FullRemoval_Succeeds() public {
        _createAuction();

        // Alice places a bid
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Warp to auction end and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // After settlement, Alice should be able to remove her position
        // Note: The partial removal check only applies during Active phase
        _removeBid(alice, aliceTickLower, aliceLiquidity, alicePos);
    }

    /// @notice Test that after settlement, partial removal still works (no check in non-Active phase)
    function test_afterSettlement_PartialRemoval_Succeeds() public {
        _createAuction();

        // Alice places a bid
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        uint256 alicePos = _addBid(alice, aliceTickLower, aliceLiquidity);

        // Warp to auction end and settle
        vm.warp(auction.auctionEndTime() + 1);
        auction.settleAuction();

        // After settlement, partial removal should work (check only in Active phase)
        uint128 partialLiquidity = aliceLiquidity / 2;
        _removeBid(alice, aliceTickLower, partialLiquidity, alicePos);

        // Can remove the rest
        _removeBid(alice, aliceTickLower, partialLiquidity, alicePos);
    }

    // ============ Tests: Edge Cases ============

    /// @notice Test removal with minimum liquidity position
    function test_fullRemoval_MinimumLiquidity_Succeeds() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob places minimum liquidity bid (out of range)
        int24 bobTickLower = -6000;
        uint128 bobLiquidity = 1e15; // Minimum liquidity
        uint256 bobPos = _addBid(bob, bobTickLower, bobLiquidity);

        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");

        // Full removal should succeed
        _removeBid(bob, bobTickLower, bobLiquidity, bobPos);
    }

    /// @notice Test that multiple positions at same tick can be individually removed
    function test_multiplePositionsSameTick_IndividualFullRemoval() public {
        _createAuction();

        // Alice places a bid that absorbs all tokens (in-range)
        int24 aliceTickLower = 0;
        uint128 aliceLiquidity = 2000 ether;
        _addBid(alice, aliceTickLower, aliceLiquidity);

        // Bob and Carol place bids at same lower tick (out of range)
        int24 outOfRangeTick = -6000;
        uint128 bobLiquidity = 1000 ether;
        uint128 carolLiquidity = 500 ether;

        uint256 bobPos = _addBid(bob, outOfRangeTick, bobLiquidity);

        // Carol needs a different salt, so we use the next position ID
        address carol = address(0xca401);
        TestERC20(numeraire).transfer(carol, 10_000_000 ether);
        TestERC20(token0).transfer(carol, 10_000_000 ether);

        int24 tickUpper = outOfRangeTick + tickSpacing;
        uint256 carolPos = auction.nextPositionId();

        vm.startPrank(carol);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: outOfRangeTick,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(carolLiquidity)),
                salt: bytes32(carolPos)
            }),
            abi.encode(carol)
        );
        vm.stopPrank();

        // Both should be out of range
        assertFalse(auction.isInRange(bobPos), "Bob should be out of range");
        assertFalse(auction.isInRange(carolPos), "Carol should be out of range");

        // Check total liquidity at tick
        assertEq(
            auction.liquidityAtTick(outOfRangeTick),
            bobLiquidity + carolLiquidity,
            "Total liquidity should be sum"
        );

        // Bob removes his full position
        _removeBid(bob, outOfRangeTick, bobLiquidity, bobPos);

        // Carol's liquidity should still be there
        assertEq(auction.liquidityAtTick(outOfRangeTick), carolLiquidity, "Carol's liquidity should remain");

        // Carol removes her full position
        vm.startPrank(carol);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: outOfRangeTick,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(carolLiquidity)),
                salt: bytes32(carolPos)
            }),
            abi.encode(carol)
        );
        vm.stopPrank();

        // Tick should have 0 liquidity now
        assertEq(auction.liquidityAtTick(outOfRangeTick), 0, "Tick should have 0 liquidity after all removals");
    }
}
