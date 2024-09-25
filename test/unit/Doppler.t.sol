pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {Unauthorized} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";

contract DopplerTest is BaseTest {
    // =========================================================================
    //                          Integration Tests
    // =========================================================================

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
