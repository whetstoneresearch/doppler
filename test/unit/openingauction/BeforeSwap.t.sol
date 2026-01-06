// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction } from "src/interfaces/IOpeningAuction.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

contract BeforeSwapTest is OpeningAuctionBaseTest {
    function test_beforeSwap_RevertsSwapsNotAllowedDuringAuction() public {
        // Try to swap during active auction
        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.SwapsNotAllowedDuringAuction.selector);
        hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
    }

    function test_beforeSwap_AllowsSelfToSwap() public {
        // The hook itself should be allowed to swap (for settlement)
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(
            address(hook),
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeSwap.selector);
    }

    function test_beforeSwap_AllowsSwapsAfterSettlement() public {
        _warpToAuctionEnd();
        hook.settleAuction();

        // Swaps are still restricted to the hook itself
        vm.prank(address(manager));
        vm.expectRevert(IOpeningAuction.SwapsNotAllowedDuringAuction.selector);
        hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
    }
}
