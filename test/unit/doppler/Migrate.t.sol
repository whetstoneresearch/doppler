// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { StateLibrary, IPoolManager, PoolId } from "@v4-core/libraries/StateLibrary.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { SenderNotInitializer, CannotMigrate, MAX_SWAP_FEE } from "src/Doppler.sol";
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
        goToStartingTime();

        bool canMigrate;

        do {
            buyExactIn(hook.minimumProceeds());
            (,,, uint256 totalProceeds,,) = hook.state();
            canMigrate = totalProceeds > hook.minimumProceeds();

            goToNextEpoch();
        } while (!canMigrate);

        goToEndingTime();
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        uint256 numPDSlugs = hook.getNumPDSlugs();
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
        (uint256 bought, uint256 used) =
            buyExactIn(hook.minimumProceeds() * MAX_SWAP_FEE / (MAX_SWAP_FEE - hook.initialLpFee()) + 1);
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
            assertEq(
                feeGrowthInside0X128,
                feeGrowthInside0LastX128,
                string.concat("feeGrowth0 should be equal in position ", vm.toString(i))
            );
            assertEq(
                feeGrowthInside1X128,
                feeGrowthInside1LastX128,
                string.concat("feeGrowth1 should be equal in position ", vm.toString(i))
            );
        }
    }

    function test_migrate_NoMoreFundsInHook() public {
        vm.warp(hook.startingTime());
        buyExactIn(hook.minimumProceeds() * MAX_SWAP_FEE / (MAX_SWAP_FEE - hook.initialLpFee()) + 1);
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

        (uint256 bought, uint256 used) =
            buyExactIn(hook.minimumProceeds() * MAX_SWAP_FEE / (MAX_SWAP_FEE - hook.initialLpFee()) + 1);

        vm.warp(hook.endingTime());
        vm.prank(hook.initializer());
        (,, uint128 fees0, uint128 balance0,, uint128 fees1, uint128 balance1) = hook.migrate(address(0xbeef));
        uint256 usedLessFee = FullMath.mulDiv(used, MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);
        uint256 expectedFees = used - usedLessFee;

        uint256 managerToken0Dust =
            token0 == address(0) ? address(manager).balance : ERC20(token0).balanceOf(address(manager));
        uint256 managerToken1Dust = ERC20(token1).balanceOf(address(manager));

        if (isToken0) {
            assertApproxEqAbs(fees1, expectedFees, 10, "fees1 should be equal to expectedFees");
            assertApproxEqAbs(fees0, 0, 10, "fees0 should be 0");
            assertEq(
                initialHookAssetBalance + initialManagerAssetBalance - bought - managerToken0Dust,
                balance0,
                "balance0 is wrong"
            );
            assertEq(used - managerToken1Dust, balance1, "balance1 should be equal to used");
        } else {
            assertApproxEqAbs(fees0, expectedFees, 10, "fees0 should be equal to expectedFees");
            assertApproxEqAbs(fees1, 0, 10, "fees1 should be 0");
            assertEq(
                initialHookAssetBalance + initialManagerAssetBalance - bought - managerToken1Dust,
                balance1,
                "balance1 is wrong"
            );
            assertEq(used - managerToken0Dust, balance0, "balance0 should be equal to used");
        }
    }
}
