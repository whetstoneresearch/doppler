// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract BeforeSwapTest is BaseTest {
    function testBeforeSwap_RevertsIfNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1 }),
            ""
        );
    }
}
