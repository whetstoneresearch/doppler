// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";

/// @title OpeningAuctionBidQuoteGas
/// @notice Gas benchmarks for add-bid quoting as active ticks increase
contract OpeningAuctionBidQuoteGas is OpeningAuctionBaseTest {
    uint128 constant LIQ = 1e18;

    function getGasTestConfig() public pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 7 days,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: -887_220,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1
        });
    }

    function setUp() public override {
        manager = new PoolManager(address(this));
        _deployTokens();
        _deployOpeningAuction(getGasTestConfig(), 1_000_000 ether);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(token0).transfer(alice, 100_000_000 ether);
        TestERC20(token1).transfer(alice, 100_000_000 ether);

        vm.startPrank(alice);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _addBidNoApprove(address user, int24 tickLower, uint128 liquidity, bytes32 salt) internal {
        vm.prank(user);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user)
        );
    }

    function _seedUniqueTicks(uint256 n, int24 startTick, int24 step) internal {
        for (uint256 i = 0; i < n; i++) {
            int24 tickLower = startTick + int24(int256(i)) * step;
            if (tickLower >= TickMath.MAX_TICK - key.tickSpacing) {
                break;
            }
            _addBidNoApprove(alice, tickLower, LIQ, keccak256(abi.encode("seed", i)));
        }
    }

    function _measureAddGas(uint256 activeTicks, int24 step, string memory label) internal {
        int24 minTick = hook.minAcceptableTick();
        int24 start = ((minTick / key.tickSpacing) + 1) * key.tickSpacing;

        _seedUniqueTicks(activeTicks, start, step);

        int24 targetTick = start;

        uint256 gasBefore = gasleft();
        _addBidNoApprove(alice, targetTick, LIQ, keccak256(abi.encode(label, activeTicks)));
        uint256 gasUsed = gasBefore - gasleft();

        string memory message =
            string.concat(label, " addBid gas | activeTicks:", vm.toString(activeTicks));
        console.log(message, gasUsed);
        vm.snapshotGasLastCall("OpeningAuction", string.concat(label, "_AddBid_", vm.toString(activeTicks), "Ticks"));
    }

    function test_gas_addBid_dense_1Tick() public {
        _measureAddGas(1, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_dense_5Ticks() public {
        _measureAddGas(5, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_dense_10Ticks() public {
        _measureAddGas(10, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_dense_25Ticks() public {
        _measureAddGas(25, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_dense_50Ticks() public {
        _measureAddGas(50, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_dense_100Ticks() public {
        _measureAddGas(100, key.tickSpacing, "Dense");
    }

    function test_gas_addBid_sparse_1Tick() public {
        _measureAddGas(1, key.tickSpacing * 20, "Sparse");
    }

    function test_gas_addBid_sparse_5Ticks() public {
        _measureAddGas(5, key.tickSpacing * 20, "Sparse");
    }

    function test_gas_addBid_sparse_10Ticks() public {
        _measureAddGas(10, key.tickSpacing * 20, "Sparse");
    }

    function test_gas_addBid_sparse_25Ticks() public {
        _measureAddGas(25, key.tickSpacing * 20, "Sparse");
    }

    function test_gas_addBid_sparse_50Ticks() public {
        _measureAddGas(50, key.tickSpacing * 20, "Sparse");
    }

    function test_gas_addBid_sparse_100Ticks() public {
        _measureAddGas(100, key.tickSpacing * 20, "Sparse");
    }
}
