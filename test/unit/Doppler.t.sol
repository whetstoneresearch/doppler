pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {BaseTest} from "test/shared/BaseTest.sol";

contract DopplerTest is BaseTest {
    // =========================================================================
    //                   _getExpectedAmountSold Unit Tests
    // =========================================================================

    function testGetElapsedGamma_ReturnsExpectedAmountSold() public {
        uint256 timestamp = hook.getStartingTime();
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
        );

        timestamp = hook.getStartingTime() + hook.getEpochLength();
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
        );

        timestamp = hook.getStartingTime() + hook.getEpochLength() * 2;
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
        );

        timestamp = hook.getEndingTime() - hook.getEpochLength() * 2;
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
        );

        timestamp = hook.getEndingTime() - hook.getEpochLength();
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
        );

        timestamp = hook.getEndingTime();
        vm.warp(timestamp);

        assertEq(
            hook.getElapsedGamma(), int256(hook.getNormalizedTimeElapsed(timestamp)) * int256(hook.getGamma()) / 1e18
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
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(accumulator, key.tickSpacing);
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
