// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
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

    function test_computeLowerSlugData() public {
        vm.warp(hook.startingTime() + hook.epochLength() * 25);
        SlugData memory slug = hook.computeLowerSlugData(
            key, 48_004_403_943_716_531, 51_856_904_538_340_935, 437_152_299_985_969_633_423, 91_168, 91_176
        );

        assertTrue(slug.tickLower < slug.tickUpper);

        console.log(slug.tickLower);
        console.log(slug.tickUpper);
    }

    function goNextEpoch() public {
        vm.warp(hook.startingTime() + (hook.getCurrentEpoch() * (hook.epochLength() + 1)));
    }

    function test_goNextEpoch() public {
        assertEq(hook.getCurrentEpoch(), 1, "Should start at one");
        goNextEpoch();
        assertEq(hook.getCurrentEpoch(), 2);
        goNextEpoch();
        goNextEpoch();
        assertEq(hook.getCurrentEpoch(), 4);
    }

    function _buy(
        uint256 amount
    ) public {
        require(amount <= uint256(type(int256).max), "Amount exceeds int256 max");

        TestERC20(numeraire).mint(address(this), amount);
        TestERC20(numeraire).approve(address(swapRouter), amount);

        uint256 preBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 preBalance1 = TestERC20(token1).balanceOf(address(this));

        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams(!isToken0, int256(amount), isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        uint256 postBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 postBalance1 = TestERC20(token1).balanceOf(address(this));

        console.log("delta0", delta.amount0());
        console.log("delta1", delta.amount1());

        /*
        if (isToken0) {
            assertEq(postBalance0, preBalance0 + uint256(int256(delta.amount0())), "Token 0 balance mismatch");
            assertEq(postBalance1, preBalance1 - uint256(int256(delta.amount1())), "Token 1 balance mismatch");
        } else {
            assertEq(postBalance0, preBalance0 - uint256(int256(delta.amount0())), "Token 0 balance mismatch");
            assertEq(postBalance1, preBalance1 + uint256(int256(delta.amount1())), "Token 1 balance mismatch");
        }
        */
    }

    function test_swap_what() public {
        assertEq(hook.getCurrentEpoch(), 1, "Should start at one");
        goNextEpoch();

        goNextEpoch();
        goNextEpoch();
        goNextEpoch();

        console.log("numTokensToSell", hook.numTokensToSell());

        _buy(1_765_966_115_684_030_849_982_404_392_077);

        (,, uint256 totalTokensSold, uint256 totalProceeds, uint256 totalTokensSoldLastEpoch,) = hook.state();
        console.log("totalTokensSold", totalTokensSold);
        console.log("totalProceeds", totalProceeds);
        console.log("totalTokensSoldLastEpoch", totalTokensSoldLastEpoch);

        (,, uint128 liquidity,) = hook.positions(LOWER_SLUG_SALT);
        console.log("lowerSlug.liquitiy", liquidity);

        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        _buy(654_526_008_458_728_267);
        (,, liquidity,) = hook.positions(LOWER_SLUG_SALT);
        console.log("lowerSlug.liquitiy", liquidity);

        goNextEpoch();

        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        console.log("WHAT!");
        _buy(8_865_492);
        console.log("WHAT!");
        goNextEpoch();

        console.log("Current epoch", hook.getCurrentEpoch());
        console.log("Max epochs", hook.getTotalEpochs());

        console.log("end?", block.timestamp >= hook.endingTime());

        (,, liquidity,) = hook.positions(LOWER_SLUG_SALT);
        console.log("lowerSlug.liquitiy", liquidity);

        (,, totalTokensSold, totalProceeds, totalTokensSoldLastEpoch,) = hook.state();
        console.log("totalTokensSold", totalTokensSold);
        console.log("totalProceeds", totalProceeds);
        console.log("totalTokensSoldLastEpoch", totalTokensSoldLastEpoch);
        _buy(2_023_415_125);
        /*

        console.log("WHAT!!");
        buy(-1_863_356_641);
        console.log("WHAT!");
        buy(-7836);
        console.log("WHAT!");
        goNextEpoch();
        buy(-2_936_100);
        goNextEpoch();
        buy(-3630);
        buy(-26_999);
        goNextEpoch();
        goNextEpoch();
        console.log("WHAT!");
        buy(-88_745_857_400_782_139_919_628_676_743_698_271_562_583_316_451_352);
        console.log("WHAT?");
        (,, liquidity,) = hook.positions("1");
        console.log("lowerSlug.liquitiy", liquidity);
        goNextEpoch();
        goNextEpoch();
        buy(-965_430_616_177_411_934_095_361_875_558_615_015);
        (,, liquidity,) = hook.positions("1");
        console.log("lowerSlug.liquitiy", liquidity);
        goNextEpoch();
        goNextEpoch();
        buy(-5763);
        goNextEpoch();
        goNextEpoch();
        goNextEpoch();
        buy(-5249);
        goNextEpoch();
        (,, liquidity,) = hook.positions("1");
        console.log("lowerSlug.liquitiy", liquidity);
        uint256 amount = 2_023_415_125;
        // assertEq(amount, uint256(-(-int256(amount))));
        // assertLe(amount, uint256(type(int256).max));

        TestERC20(numeraire).mint(address(this), uint256(amount));
        TestERC20(numeraire).approve(address(swapRouter), uint256(amount));

        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams(!isToken0, int256(amount), isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        // buyExactIn(amount);
        // goNextEpoch();
        // buy(-1_212_299_942_327);
        */
    }
}
