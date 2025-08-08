// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { StateLibrary, IPoolManager, PoolId } from "@v4-core/libraries/StateLibrary.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { SenderNotInitializer, CannotMigrate, MAX_SWAP_FEE, Position } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

import { console } from "forge-std/console.sol";

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
        buyUntilMinimumProceeds();
        goToEndingTime();
        prankAndMigrate();

        uint256 numPDSlugs = hook.getNumPDSlugs();
        for (uint256 i = 1; i < numPDSlugs + 3; i++) {
            (int24 tickLower, int24 tickUpper,,) = hook.positions(bytes32(i));
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(hook), isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower, bytes32(i)
            );
            assertEq(liquidity, 0, "liquidity should be 0");
        }
    }

    // FIXME: This test will fail because we're deleting the positions after migrating, we should
    // cache them and then check the fee growth.
    function test_migrate_CollectAllFees() public {
        vm.skip(true);
        goToStartingTime();
        (, uint256 totalSpent) = buyUntilMinimumProceeds();
        sellExactOut(totalSpent / 20);
        buyExactIn(totalSpent / 20);
        goToEndingTime();

        uint256 positionsCount = hook.getNumPDSlugs() + 3;
        Position[] memory positions = new Position[](positionsCount);

        for (uint256 i = 1; i < positionsCount; i++) {
            (int24 tickLower, int24 tickUpper,, uint8 salt) = hook.positions(bytes32(i));
            positions[i - 1] = Position({
                tickLower: isToken0 ? tickLower : tickUpper,
                tickUpper: isToken0 ? tickUpper : tickLower,
                liquidity: 0,
                salt: salt
            });
        }

        for (uint256 i; i < positions.length; i++) {
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = manager.getPositionInfo(
                poolId,
                address(hook),
                positions[i].tickLower,
                positions[i].tickUpper,
                bytes32(uint256(positions[i].salt))
            );
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                manager.getFeeGrowthInside(poolId, positions[i].tickLower, positions[i].tickUpper);
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

        prankAndMigrate();
    }

    function test_migrate_NoMoreFundsInHook() public {
        goToStartingTime();
        buyUntilMinimumProceeds();
        goToEndingTime();
        prankAndMigrate();

        if (usingEth) {
            assertEq(address(hook).balance, 0, "hook should have no ETH");
        } else {
            assertEq(ERC20(token0).balanceOf(address(hook)), 0, "hook should have no token0");
        }

        assertEq(ERC20(token1).balanceOf(address(hook)), 0, "hook should have no token1");
    }

    function test_migrate_NoMoreFundsInPoolManager() public {
        goToStartingTime();
        buyUntilMinimumProceeds();
        goToEndingTime();
        prankAndMigrate();

        assertApproxEqRel(
            usingEth ? address(manager).balance : ERC20(numeraire).balanceOf(address(manager)),
            manager.protocolFeesAccrued(Currency.wrap(numeraire)),
            0.00001 ether,
            "Manager should only have protocol fees left"
        );

        assertLt(ERC20(asset).balanceOf(address(manager)), 100, "Manager should have no asset left");
    }

    function test_migrate_ReturnedValues() public {
        address recipient = address(0xbeefbeef);
        goToStartingTime();

        uint256 initialHookAssetBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(hook));
        uint256 initialManagerAssetBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(manager));

        (uint256 boughtA, uint256 spentA) = buyExactIn(1 ether);
        goToNextEpoch();
        (uint256 soldB, uint256 receivedB) = sellExactIn(boughtA / 2);
        goToNextEpoch();
        (uint256 boughtC, uint256 spentC) = buyUntilMinimumProceeds();
        goToEndingTime();

        uint256 feesAccrued0;
        uint256 feesAccrued1;

        uint256 feesA = spentA - FullMath.mulDiv(spentA, MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);
        uint256 feesB = soldB - FullMath.mulDiv(soldB, MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);
        uint256 feesC = spentC - FullMath.mulDiv(spentC, MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);

        if (isToken0) {
            feesAccrued0 = feesB;
            feesAccrued1 = feesA + feesC;
        } else {
            feesAccrued0 = feesA + feesC;
            feesAccrued1 = feesB;
        }

        (,, uint128 fees0, uint128 balance0,, uint128 fees1, uint128 balance1) = prankAndMigrate(recipient);

        assertApproxEqRel(fees0, feesAccrued0, 0.000001 ether, "fees0 should be equal to feesAccrued0");
        assertApproxEqRel(fees1, feesAccrued1, 0.000001 ether, "fees1 should be equal to feesAccrued1");

        uint256 managerDust0 = usingEth ? address(manager).balance : ERC20(token0).balanceOf(address(manager));
        uint256 managerDust1 = ERC20(token1).balanceOf(address(manager));
        uint256 recipientBalance0 = usingEth ? address(0xbeef).balance : ERC20(token0).balanceOf(recipient);
    }
}
