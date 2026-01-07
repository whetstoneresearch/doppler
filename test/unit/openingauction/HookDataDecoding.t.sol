// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { AuctionPosition, OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";

contract HookDataDecodingTest is OpeningAuctionBaseTest {
    mapping(uint256 => bytes32) internal positionSalts;

    function setUp() public override {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        _deployTokens();

        // Deploy opening auction
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 10_000; // force tokensToSell = 0 to keep positions out of range
        _deployOpeningAuction(config, DEFAULT_AUCTION_TOKENS);

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        // Approve routers
        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Fund users
        TestERC20(token0).transfer(alice, 1_000_000 ether);
        TestERC20(token1).transfer(alice, 1_000_000 ether);
        TestERC20(token0).transfer(bob, 1_000_000 ether);
        TestERC20(token1).transfer(bob, 1_000_000 ether);
    }

    function _addBidPacked(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + key.tickSpacing;
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encodePacked(user)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(user, tickLower, tickUpper, salt);
        positionSalts[positionId] = salt;
    }

    function _removeBidPacked(address user, int24 tickLower, uint128 liquidity, uint256 positionId) internal {
        int24 tickUpper = tickLower + key.tickSpacing;

        vm.startPrank(user);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: positionSalts[positionId]
            }),
            abi.encodePacked(user)
        );
        vm.stopPrank();
    }

    function test_hookDataPacked_addLiquidityTracksOwner() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 amount = 1 ether;

        uint256 positionId = _addBidPacked(alice, tickLower, amount);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.owner, alice);
        assertEq(pos.tickLower, tickLower);
    }

    function test_hookDataPacked_removeLiquiditySucceeds() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint128 amount = 1 ether;

        uint256 positionId = _addBidPacked(alice, tickLower, amount);
        _removeBidPacked(alice, tickLower, amount, positionId);

        AuctionPosition memory pos = hook.positions(positionId);
        assertEq(pos.liquidity, 0);
    }
}
