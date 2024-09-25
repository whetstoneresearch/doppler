pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {InvalidTime, SwapBelowRange} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";

contract SwapTest is BaseTest {
    function test_swap_RevertsBeforeStartTimeAndAfterEndTime() public {
        vm.warp(hook.getStartingTime() - 1); // 1 second before the start time

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(InvalidTime.selector)
            )
        );
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getEndingTime() + 1); // 1 second after the end time

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(InvalidTime.selector)
            )
        );
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_DoesNotRebalanceTwiceInSameEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
            hook.state();

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
            hook.state();

        // Ensure that state hasn't updated since we're still in the same epoch
        assertEq(lastEpoch, lastEpoch2);
        assertEq(tickAccumulator, tickAccumulator2);
        assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

        // Ensure that we're tracking the amount of tokens sold
        assertEq(totalTokensSold + 1 ether, totalTokensSold2);
    }

    function test_swap_UpdatesLastEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch,,,,) = hook.state();

        assertEq(lastEpoch, 1);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (lastEpoch,,,,) = hook.state();

        assertEq(lastEpoch, 2);
    }

    function test_swap_UpdatesTotalTokensSoldLastEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = hook.state();

        assertEq(totalTokensSold, 2e18);
        assertEq(totalTokensSoldLastEpoch, 1e18);
    }

    function test_swap_MaxDutchAuction_NetSoldZero() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
            hook.state();

        assertEq(lastEpoch, 1);
        // We sold 1e18 tokens just now
        assertEq(totalTokensSold, 1e18);
        // Previous epoch didn't exist so no tokens would have been sold at the time
        assertEq(totalTokensSoldLastEpoch, 0);

        // Swap tokens back into the pool, netSold == 0
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -1 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch2,, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) = hook.state();

        assertEq(lastEpoch2, 1);
        // We unsold all the previously sold tokens
        assertEq(totalTokensSold2, 0);
        // This is unchanged because we're still referencing the epoch which didn't exist
        assertEq(totalTokensSoldLastEpoch2, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3) =
            hook.state();

        assertEq(lastEpoch3, 2);
        // We sold some tokens just now
        assertEq(totalTokensSold3, 1e18);
        // The net sold amount in the previous epoch was 0
        assertEq(totalTokensSoldLastEpoch3, 0);

        // Assert that we reduced the accumulator by the max amount as intended
        // We divide by 1e18 since getMaxTickDeltaPerEpoch returns a 18 decimal fixed point value
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();
        assertEq(tickAccumulator3, tickAccumulator + maxTickDeltaPerEpoch);
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterInitialization() public {
        vm.warp(hook.getStartingTime());

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(SwapBelowRange.selector)
            )
        );
        // Attempt 0 amount swap below lower slug
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, 1, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
        vm.warp(hook.getStartingTime());

        // Sell some tokens
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // Swap to trigger lower slug being created
        // Unsell half of sold tokens
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -0.5 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(SwapBelowRange.selector)
            )
        );
        // Unsell beyond remaining tokens, moving price below lower slug
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -0.6 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }
}
