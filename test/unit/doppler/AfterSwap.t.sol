// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract AfterSwapTest is BaseTest {
    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_revertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1 }),
            toBalanceDelta(0, 0),
            ""
        );
    }
}
