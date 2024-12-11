pragma solidity 0.8.26;

import { IPoolManager } from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import { toBalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { BaseHook } from "v4-periphery/src/base/hooks/BaseHook.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";

import { BaseTest, TestERC20 } from "test/shared/BaseTest.sol";

/// @dev forge test -vvv --mc DopplerBeforeSwapTest --via-ir
/// TODO: I duplicated this from the test file just to test this out for now.
contract BeforeSwapTest is BaseTest {
    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1 }),
            ""
        );
    }
}
