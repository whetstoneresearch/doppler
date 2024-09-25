pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {Unauthorized, InvalidTime, SwapBelowRange} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";

contract DopplerTest is BaseTest {
    // =========================================================================
    //                          Integration Tests
    // =========================================================================

    function testRevertsBeforeStartTimeAndAfterEndTime() public {
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

    function testDoesNotRebalanceTwiceInSameEpoch() public {
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

    function testUpdatesLastEpoch() public {
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

    function testUpdatesTotalTokensSoldLastEpoch() public {
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

    function testMaxDutchAuction_NetSoldZero() public {
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

    function testCannotSwapBelowLowerSlug_AfterInitialization() public {
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

    function testCannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
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

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            ""
        );
    }

    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_revertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            toBalanceDelta(0, 0),
            ""
        );
    }

    // =========================================================================
    //                      beforeAddLiquidity Unit Tests
    // =========================================================================

    function testBeforeAddLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(this),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000,
                tickUpper: 100_000,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function testBeforeAddLiquidity_ReturnsSelectorForHookCaller() public {
        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            address(hook),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000,
                tickUpper: 100_000,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }

    function testBeforeAddLiquidity_RevertsForNonHookCaller() public {
        vm.prank(address(manager));
        vm.expectRevert(Unauthorized.selector);
        hook.beforeAddLiquidity(
            address(0xBEEF),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000,
                tickUpper: 100_000,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // =========================================================================
    //                   _getExpectedAmountSold Unit Tests
    // =========================================================================

    function testGetExpectedAmountSold_ReturnsExpectedAmountSold(uint64 timePercentage) public {
        vm.assume(timePercentage <= 1e18);

        uint256 timeElapsed = (hook.getEndingTime() - hook.getStartingTime()) * timePercentage / 1e18;
        uint256 timestamp = hook.getStartingTime() + timeElapsed;
        vm.warp(timestamp);

        uint256 expectedAmountSold = hook.getExpectedAmountSold(timestamp);

        assertApproxEqAbs(
            timestamp,
            hook.getStartingTime()
                + (expectedAmountSold * 1e18 / hook.getNumTokensToSell()) * (hook.getEndingTime() - hook.getStartingTime())
                    / 1e18,
            1
        );
    }

    // =========================================================================
    //                  _getMaxTickDeltaPerEpoch Unit Tests
    // =========================================================================

    function testGetMaxTickDeltaPerEpoch_ReturnsExpectedAmount() public view {
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        assertApproxEqAbs(
            hook.getEndingTick(),
            (
                (
                    maxTickDeltaPerEpoch
                        * (int256((hook.getEndingTime() - hook.getStartingTime())) / int256(hook.getEpochLength()))
                ) / 1e18 + hook.getStartingTick()
            ),
            1
        );
    }

    // =========================================================================
    //                   _getElapsedGamma Unit Tests
    // =========================================================================

    function testGetElapsedGamma_ReturnsExpectedAmountSold(uint8 timePercentage) public {
        vm.assume(timePercentage <= 100);
        vm.assume(timePercentage > 0);

        uint256 timeElapsed = (hook.getEndingTime() - hook.getStartingTime()) * timePercentage / 100;
        uint256 timestamp = hook.getStartingTime() + timeElapsed;
        vm.warp(timestamp);

        int256 elapsedGamma = hook.getElapsedGamma();

        assertApproxEqAbs(
            int256(hook.getGamma()),
            elapsedGamma * int256(hook.getEndingTime() - hook.getStartingTime())
                / int256(timestamp - hook.getStartingTime()),
            1
        );
    }

    // =========================================================================
    //                   _getTicksBasedOnState Unit Tests
    // =========================================================================

    // TODO: int16 accumulator might over/underflow with certain states
    //       Consider whether we need to protect against this in the contract or whether it's not a concern
    function testGetTicksBasedOnState_ReturnsExpectedAmountSold(int16 accumulator) public view {
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(int24(accumulator), key.tickSpacing);
        int24 gamma = hook.getGamma();

        if (hook.getStartingTick() > hook.getEndingTick()) {
            assertEq(int256(gamma), tickUpper - tickLower);
        } else {
            assertEq(int256(gamma), tickLower - tickUpper);
        }
    }

    // =========================================================================
    //                     _getCurrentEpoch Unit Tests
    // =========================================================================

    function testGetCurrentEpoch_ReturnsCorrectEpoch() public {
        vm.warp(hook.getStartingTime());
        uint256 currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 1);

        vm.warp(hook.getStartingTime() + hook.getEpochLength());
        currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 2);

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 2);
        currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 3);
    }

    // =========================================================================
    //                     _computeLiquidity Unit Tests
    // =========================================================================

    function testComputeLiquidity_IsSymmetric(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
        public
        view
    {}
}