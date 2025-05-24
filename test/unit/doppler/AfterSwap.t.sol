// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract AfterSwapTest is BaseTest {
    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_revertsIfNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0 }),
            toBalanceDelta(0, 0),
            ""
        );
    }
}
