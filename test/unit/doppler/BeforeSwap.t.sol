// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { CannotSwapBeforeStartTime, MaximumProceedsReached } from "src/initializers/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract BeforeSwapTest is BaseTest {
    function test_beforeSwap_RevertsIfNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0 }),
            ""
        );
    }

    function test_beforeSwap_RevertsWhenEarlyExit() public {
        hook.setEarlyExit();
        vm.prank(address(manager));
        vm.expectRevert(MaximumProceedsReached.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0 }),
            ""
        );
    }

    function test_beforeSwap_RevertsBeforeStartTime() public {
        vm.warp(hook.startingTime() - 1);
        vm.prank(address(manager));
        vm.expectRevert(CannotSwapBeforeStartTime.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0 }),
            ""
        );
    }
}
