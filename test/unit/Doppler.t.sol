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
    //                   _getTicksBasedOnState Unit Tests
    // =========================================================================

    // TODO: int16 accumulator might over/underflow with certain hook configurations
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
    //                  _getNormalizedTimeElapsed Unit Tests
    // =========================================================================

    function testGetNormalizedTimeElapsed(uint16 bps) public view {
        vm.assume(bps <= 10_000);

        uint256 endingTime = hook.getEndingTime();
        uint256 startingTime = hook.getStartingTime();
        uint256 timestamp = (endingTime - startingTime) * bps / 10_000 + startingTime;

        // Assert that the result is within one bps of the expected value
        assertApproxEqAbs(hook.getNormalizedTimeElapsed(timestamp), uint256(bps) * 1e14, 0.5e14);
    }

    // =========================================================================
    //                       _getGammaShare Unit Tests
    // =========================================================================

    function testGetGammaShare() public view {
        uint256 endingTime = hook.getEndingTime();
        uint256 startingTime = hook.getStartingTime();
        uint256 epochLength = hook.getEpochLength();

        assertApproxEqAbs(epochLength, uint256(hook.getGammaShare()) * (endingTime - startingTime) / 1e18, 1);
    }

    // =========================================================================
    //                       _getEpochEndWithOffset Unit Tests
    // =========================================================================

    function testGetEpochEndWithOffset() public {
        uint256 startingTime = hook.getStartingTime();
        uint256 endingTime = hook.getEndingTime();
        uint256 epochLength = hook.getEpochLength();

        // Assert cases without offset

        vm.warp(startingTime - 1);
        uint256 epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength);

        vm.warp(startingTime);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength);

        vm.warp(startingTime + epochLength);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime + epochLength * 2);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength * 3);

        vm.warp(endingTime - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, endingTime);

        // Assert cases with epoch

        vm.warp(startingTime - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime + epochLength);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 3);

        vm.warp(startingTime + epochLength * 2);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 4);

        vm.warp(endingTime - epochLength - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, endingTime);
    }
}
