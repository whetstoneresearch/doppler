// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { StateLibrary, IPoolManager, PoolId } from "v4-core/src/libraries/StateLibrary.sol";
import { SenderNotAirlock, CannotMigrate } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract MigrateTest is BaseTest {
    using StateLibrary for IPoolManager;

    function test_migrate_RevertsIfSenderNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        hook.migrate(address(0));
    }

    function test_migrate_RevertsIfConditionsNotMet() public {
        vm.startPrank(hook.airlock());
        vm.expectRevert(CannotMigrate.selector);
        hook.migrate(address(0));
    }

    function test_migrate_RemovesAllLiquidity() public {
        uint256 numPDSlugs = hook.getNumPDSlugs();

        vm.warp(hook.getStartingTime());

        // buy minimumProceeds In
        // TODO: Check why buying only minimumProceeds is not enough
        buyExactIn(hook.getMinimumProceeds() + 1 ether);

        vm.warp(hook.getEndingTime());
        vm.prank(hook.airlock());
        hook.migrate(address(0xbeef));

        for (uint256 i = 1; i < numPDSlugs + 3; i++) {
            (int24 tickLower, int24 tickUpper,,) = hook.positions(bytes32(i));
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(hook), isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower, bytes32(i)
            );
            assertEq(liquidity, 0, "liquidity should be 0");
        }
    }

    function test_migrate_NoMoreFundsInHook() public {
        vm.warp(hook.getStartingTime());

        buyExactOut(hook.getMinimumProceeds());

        vm.warp(hook.getEndingTime());
        vm.prank(hook.airlock());
        hook.migrate(address(0xbeef));

        if (usingEth) {
            assertEq(address(hook).balance, 0, "hook should have no ETH");
        } else {
            assertEq(ERC20(token0).balanceOf(address(hook)), 0, "hook should have no token0");
        }

        assertEq(ERC20(token1).balanceOf(address(hook)), 0, "hook should have no token1");
    }
}
