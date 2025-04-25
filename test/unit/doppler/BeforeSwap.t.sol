// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

/// @dev forge test -vvv --mc DopplerBeforeSwapTest --via-ir
/// TODO: I duplicated this from the test file just to test this out for now.
contract BeforeSwapTest is BaseTest {
    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

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
