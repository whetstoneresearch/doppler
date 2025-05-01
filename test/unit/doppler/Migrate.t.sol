// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { StateLibrary, IPoolManager, PoolId } from "@v4-core/libraries/StateLibrary.sol";
import { SenderNotInitializer, CannotMigrate } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract MigrateTest is BaseTest {
    using StateLibrary for IPoolManager;

    function test_migrate_RevertsIfSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        hook.migrate(address(0));
    }

    function test_migrate_RevertsIfConditionsNotMet() public {
        vm.startPrank(hook.initializer());
        vm.expectRevert(CannotMigrate.selector);
        hook.migrate(address(0));
    }

    function test_migrate_RemovesAllLiquidity() public {
        uint256 numPDSlugs = hook.getNumPDSlugs();

        vm.warp(hook.startingTime());

        // buy minimumProceeds In
        // TODO: Check why buying only minimumProceeds is not enough
        buyExactIn(hook.minimumProceeds() + 1 ether);

        vm.warp(hook.endingTime());
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        for (uint256 i = 1; i < numPDSlugs + 3; i++) {
            (int24 tickLower, int24 tickUpper,,) = hook.positions(bytes32(i));
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(hook), isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower, bytes32(i)
            );
            assertEq(liquidity, 0, "liquidity should be 0");
        }
    }

    function test_migrate_CollectAllFees() public {
        vm.warp(hook.startingTime());
        (uint256 bought,) = buyExactIn(hook.minimumProceeds() + 1 ether);
        sellExactIn(bought / 2);
        buyExactIn(hook.minimumProceeds());

        vm.warp(hook.endingTime());
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        uint256 numPDSlugs = hook.getNumPDSlugs();

        for (uint256 i = 1; i < numPDSlugs + 3; i++) {
            (int24 tickLower, int24 tickUpper,,) = hook.positions(bytes32(i));
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = manager.getPositionInfo(
                poolId, address(hook), isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower, bytes32(i)
            );
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                manager.getFeeGrowthInside(poolId, isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower);
            assertEq(feeGrowthInside0X128, feeGrowthInside0LastX128, "feeGrowth0 should be equal");
            assertEq(feeGrowthInside1X128, feeGrowthInside1LastX128, "feeGrowth1 should be equal");
        }
    }

    function test_migrate_NoMoreFundsInHook() public {
        vm.warp(hook.startingTime());

        buyExactOut(hook.minimumProceeds());

        vm.warp(hook.endingTime());
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        if (usingEth) {
            assertEq(address(hook).balance, 0, "hook should have no ETH");
        } else {
            assertEq(ERC20(token0).balanceOf(address(hook)), 0, "hook should have no token0");
        }

        assertEq(ERC20(token1).balanceOf(address(hook)), 0, "hook should have no token1");
    }

    function test_migrate_ReturnedValues() public {
        vm.warp(hook.startingTime());

        uint256 initialHookAssetBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(hook));
        uint256 initialManagerAssetBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(manager));

        (uint256 bought, uint256 used) = buyExactOut(hook.minimumProceeds());

        vm.warp(hook.endingTime());
        vm.prank(hook.initializer());
        (,, uint128 fees0, uint128 balance0,, uint128 fees1, uint128 balance1) = hook.migrate(address(0xbeef));
        uint256 expectedFees = used * uint24(vm.envOr("FEE", uint24(0))) / 1e6;

        uint256 managerToken0Dust =
            token0 == address(0) ? address(manager).balance : ERC20(token0).balanceOf(address(manager));
        uint256 managerToken1Dust = ERC20(token1).balanceOf(address(manager));

        if (isToken0) {
            assertEq(fees1, expectedFees, "fees1 should be equal to expectedFees");
            assertEq(fees0, 0, "fees0 should be 0");
            assertEq(
                initialHookAssetBalance + initialManagerAssetBalance - bought - managerToken0Dust,
                balance0,
                "balance0 is wrong"
            );
            assertEq(used - managerToken1Dust, balance1, "balance1 should be equal to used");
        } else {
            assertEq(fees0, expectedFees, "fees0 should be equal to expectedFees");
            assertEq(fees1, 0, "fees1 should be 0");
            assertEq(
                initialHookAssetBalance + initialManagerAssetBalance - bought - managerToken1Dust,
                balance1,
                "balance1 is wrong"
            );
            assertEq(used - managerToken0Dust, balance0, "balance0 should be equal to used");
        }
    }
}
