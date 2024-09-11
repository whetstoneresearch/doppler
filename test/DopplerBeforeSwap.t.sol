pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {BaseTest} from "./BaseTest.sol";

/// @dev forge test -vvv --mc DopplerBeforeSwapTest --via-ir
/// TODO: I duplicated this from the test file just to test this out for now.
contract DopplerBeforeSwapTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_DoesNotRebalanceBeforeStartTime() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime() - 1); // 1 second before the start time

            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch,
                int256 tickAccumulator,
                uint256 totalTokensSold,
                uint256 totalProceeds,
                uint256 totalTokensSoldLastEpoch
            ) = ghosts()[i].hook.state();

            assertEq(lastEpoch, 0);
            assertEq(tickAccumulator, 0);
            assertEq(totalTokensSold, 0);
            assertEq(totalProceeds, 0);
            assertEq(totalTokensSoldLastEpoch, 0);
        }
    }

    function testBeforeSwap_DoesNotRebalanceTwiceInSameEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch,
                int256 tickAccumulator,
                uint256 totalTokensSold,
                uint256 totalProceeds,
                uint256 totalTokensSoldLastEpoch
            ) = ghosts()[i].hook.state();

            vm.prank(address(manager));
            (selector, delta, fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch2,
                int256 tickAccumulator2,
                uint256 totalTokensSold2,
                uint256 totalProceeds2,
                uint256 totalTokensSoldLastEpoch2
            ) = ghosts()[i].hook.state();

            // Ensure that state hasn't updated since we're still in the same epoch
            assertEq(lastEpoch, lastEpoch2);
            assertEq(tickAccumulator, tickAccumulator2);
            assertEq(totalTokensSold, totalTokensSold2);
            assertEq(totalProceeds, totalProceeds2);
            assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);
        }
    }

    function testBeforeSwap_UpdatesLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (uint40 lastEpoch,,,,) = ghosts()[i].hook.state();

            assertEq(lastEpoch, 1);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            vm.prank(address(manager));
            (selector, delta, fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (lastEpoch,,,,) = ghosts()[i].hook.state();

            assertEq(lastEpoch, 2);
        }
    }

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.expectRevert(SafeCallback.NotPoolManager.selector);
            ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );
        }
    }

    function testBeforeSwap_UpdatesTotalTokensSoldLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            (bytes4 selector0, int128 hookDelta) = ghosts()[i].hook.afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(100e18, -100e18),
                ""
            );

            assertEq(selector0, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            vm.prank(address(manager));
            (bytes4 selector1, BeforeSwapDelta delta, uint24 fee) = ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector1, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = ghosts()[i].hook.state();

            assertEq(totalTokensSold, 100e18);
            assertEq(totalTokensSoldLastEpoch, 100e18);
        }
    }
}

error Unauthorized();
