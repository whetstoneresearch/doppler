// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuctionConfig, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";

contract RandomAddRemoveSequencesTest is OpeningAuctionBaseTest {
    struct PositionData {
        address owner;
        int24 tickLower;
        uint128 liquidity;
        bytes32 salt;
        uint256 positionId;
        bool active;
    }

    PositionData[] internal positions;

    function setUp() public override {
        manager = new PoolManager(address(this));

        _deployTokens();

        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 10_000;
        _deployOpeningAuction(config, DEFAULT_AUCTION_TOKENS);

        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        vm.prank(initializer);
        hook.setPositionManager(address(modifyLiquidityRouter));

        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        TestERC20(token0).transfer(alice, 1_000_000 ether);
        TestERC20(token1).transfer(alice, 1_000_000 ether);
        TestERC20(token0).transfer(bob, 1_000_000 ether);
        TestERC20(token1).transfer(bob, 1_000_000 ether);
    }

    function _addPosition(address owner, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + key.tickSpacing;
        bytes32 salt = keccak256(abi.encode(owner, bidNonce++));

        vm.startPrank(owner);
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
            abi.encode(owner)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(owner, tickLower, tickUpper, salt);
        positions.push(
            PositionData({
                owner: owner,
                tickLower: tickLower,
                liquidity: liquidity,
                salt: salt,
                positionId: positionId,
                active: true
            })
        );
    }

    function _removePosition(uint256 index) internal {
        PositionData storage pos = positions[index];
        if (!pos.active) return;

        vm.startPrank(pos.owner);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickLower + key.tickSpacing,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: pos.salt
            }),
            abi.encode(pos.owner)
        );
        vm.stopPrank();

        pos.active = false;
    }

    function test_fuzz_randomAddRemoveSequences(uint256 seed) public {
        uint256 steps = 20 + (seed % 20);

        for (uint256 i = 0; i < steps; i++) {
            uint256 rand = uint256(keccak256(abi.encode(seed, i)));
            bool doAdd = positions.length == 0 || (rand & 1) == 0;

            if (doAdd) {
                address owner = (rand & 2) == 0 ? alice : bob;
                uint256 offset = (rand >> 8) % 20;
                int24 tickLower = hook.minAcceptableTick() + int24(int256(offset)) * key.tickSpacing;
                uint128 liquidity = hook.minLiquidity() + uint128(rand % 1e18);
                _addPosition(owner, tickLower, liquidity);
            } else {
                uint256 index = rand % positions.length;
                _removePosition(index);
            }
        }

        for (uint256 i = 0; i < positions.length; i++) {
            PositionData memory pos = positions[i];
            AuctionPosition memory stored = hook.positions(pos.positionId);

            if (pos.active) {
                assertEq(stored.owner, pos.owner);
                assertEq(stored.tickLower, pos.tickLower);
                assertEq(stored.liquidity, pos.liquidity);
            } else {
                assertEq(stored.liquidity, 0);
            }
        }

        for (uint256 i = 0; i < positions.length; i++) {
            PositionData memory pos = positions[i];
            if (!pos.active) continue;

            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                PositionData memory prev = positions[j];
                if (prev.active && prev.tickLower == pos.tickLower) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;

            uint256 sumLiquidity = 0;
            for (uint256 j = 0; j < positions.length; j++) {
                PositionData memory item = positions[j];
                if (item.active && item.tickLower == pos.tickLower) {
                    sumLiquidity += item.liquidity;
                }
            }

            assertEq(sumLiquidity, hook.liquidityAtTick(pos.tickLower));
        }
    }
}
