// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import {
    CannotSwapBeforeStartTime,
    SwapBelowRange,
    InvalidSwapAfterMaturityInsufficientProceeds,
    InvalidSwapAfterMaturitySufficientProceeds,
    MAX_SWAP_FEE,
    SlugData,
    Position,
    LOWER_SLUG_SALT
} from "src/Doppler.sol";

contract SwapTest is BaseTest {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for *;
    // NOTE: when testing conditions where we expect a revert using buy/sellExpectRevert,
    // we need to pass in a negative amount to specify an exactIn swap.
    // otherwise, the quoter will attempt to calculate an exactOut amount, which will fail.

    function test_swap_RevertsBeforeStartTime() public {
        vm.warp(hook.startingTime() - 1); // 1 second before the start time

        buyExpectRevert(-1 ether, CannotSwapBeforeStartTime.selector, true);
    }

    function test_swap_RevertsAfterEndTimeInsufficientProceedsAssetBuy() public {
        vm.warp(hook.startingTime()); // 1 second after the end time

        int256 minimumProceeds = int256(hook.minimumProceeds());

        buy(-minimumProceeds / 2);

        vm.warp(hook.endingTime() + 1); // 1 second after the end time

        buyExpectRevert(-1 ether, InvalidSwapAfterMaturityInsufficientProceeds.selector, true);
    }

    function test_swap_CanRepurchaseNumeraireAfterEndTimeInsufficientProceeds() public {
        vm.warp(hook.startingTime()); // 1 second after the end time

        int256 minimumProceeds = int256(hook.minimumProceeds());

        buy(-minimumProceeds / 2);

        vm.warp(hook.endingTime() + 1); // 1 second after the end time

        (,, uint256 totalTokensSold,,,) = hook.state();

        assertGt(totalTokensSold, 0);

        // assert that we can sell back all tokens
        sell(-int256(totalTokensSold));

        (,, uint256 totalTokensSold2, uint256 totalProceeds2,,) = hook.state();

        // assert that we get the totalProceeds near 0
        (uint256 amount0ExpectedFee, uint256 amount1ExpectedFee) = isToken0
            ? computeFees(uint256(totalTokensSold), uint256(minimumProceeds / 2))
            : computeFees(uint256(minimumProceeds / 2), uint256(totalTokensSold));
        assertGe(totalProceeds2, isToken0 ? amount1ExpectedFee : amount0ExpectedFee);
        assertApproxEqAbs(totalTokensSold2, isToken0 ? amount0ExpectedFee : amount1ExpectedFee, 1);
    }

    function test_swap_RevertsAfterEndTimeSufficientProceeds() public {
        vm.warp(hook.startingTime());

        int256 minimumProceeds = int256(hook.minimumProceeds());

        buy(-minimumProceeds * 11 / 10);

        vm.warp(hook.endingTime() + 1); // 1 second after the end time

        buyExpectRevert(-1 ether, InvalidSwapAfterMaturitySufficientProceeds.selector, true);
    }

    function test_swap_DoesNotRebalanceTwiceInSameEpoch() public {
        vm.warp(hook.startingTime());

        buy(1 ether);

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) =
            hook.state();

        buy(1 ether);

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        // Ensure that state hasn't updated since we're still in the same epoch
        assertEq(lastEpoch, lastEpoch2);
        assertEq(tickAccumulator, tickAccumulator2);
        assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

        // Ensure that we're tracking the amount of tokens sold
        assertEq(totalTokensSold + 1 ether, totalTokensSold2);
    }

    function test_swap_UpdatesLastEpoch() public {
        vm.warp(hook.startingTime());

        buy(1 ether);

        (uint40 lastEpoch,,,,,) = hook.state();

        assertEq(lastEpoch, 1);

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        buy(1 ether);

        (lastEpoch,,,,,) = hook.state();

        assertEq(lastEpoch, 2);
    }

    function test_swap_UpdatesTotalTokensSoldLastEpoch() public {
        vm.warp(hook.startingTime());

        buy(1 ether);

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        buy(1 ether);

        (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) = hook.state();

        assertEq(totalTokensSold, 2e18);
        assertEq(totalTokensSoldLastEpoch, 1e18);
    }

    function test_swap_UpdatesTotalProceedsAndTotalTokensSoldLessFee() public {
        vm.warp(hook.startingTime());
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        uint24 swapFee = uint16(protocolFee).calculateSwapFee(lpFee);

        int256 amountIn = 1 ether;

        uint256 amountInLessFee = FullMath.mulDiv(uint256(amountIn), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);

        buy(-amountIn);

        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

        assertEq(totalProceeds, amountInLessFee);

        amountInLessFee = FullMath.mulDiv(uint256(totalTokensSold), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);

        sell(-int256(totalTokensSold));

        (,, uint256 totalTokensSold2,,,) = hook.state();

        assertEq(totalTokensSold2, totalTokensSold - amountInLessFee);
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterInitialization() public {
        vm.warp(hook.startingTime());

        sellExpectRevert(-1 ether, SwapBelowRange.selector, false);
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
        vm.warp(hook.startingTime());

        buy(1 ether);

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // Swap to trigger lower slug being created
        // Unsell half of sold tokens
        sell(-0.5 ether);

        sellExpectRevert(-0.6 ether, SwapBelowRange.selector, false);
    }

    function test_swap_DoesNotRebalanceInTheFirstEpoch() public {
        (, int256 tickAccumulator,,,,) = hook.state();

        vm.warp(hook.startingTime());

        buy(1 ether);
        (, int256 tickAccumulator2,,,,) = hook.state();

        assertEq(tickAccumulator, tickAccumulator2);
    }

    function test_swap_ZeroFeesWhenInsufficientProceeds() public {
        vm.warp(hook.startingTime());
        (uint256 bought,) = buy(1 ether);
        vm.warp(hook.endingTime() + 1);

        (uint256 beforeFeeGrowthGlobal0, uint256 beforeFeeGrowthGlobal1) = manager.getFeeGrowthGlobals(poolId);
        sell(int256(bought));
        (uint256 afterFeeGrowthGlobal0, uint256 afterFeeGrowthGlobal1) = manager.getFeeGrowthGlobals(poolId);
        assertEq(beforeFeeGrowthGlobal0, afterFeeGrowthGlobal0, "Token 0 fee growth should not change");
        assertEq(beforeFeeGrowthGlobal1, afterFeeGrowthGlobal1, "Token 1 fee growth should not change");
    }
}
