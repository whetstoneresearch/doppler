// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseTest } from "test/shared/BaseTest.sol";
import { StateView } from "@v4-periphery/lens/StateView.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";

contract DopplerLensTest is BaseTest {
    function test_lens_fetches_consistent_ticks() public {
        vm.warp(hook.startingTime());

        bool isToken0 = hook.isToken0();

        (uint160 sqrtPriceX960, int24 tick0) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        vm.warp(hook.startingTime() + hook.epochLength());

        (uint160 sqrtPriceX961, int24 tick1) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );
        if (isToken0) {
            assertLt(tick1, tick0, "Tick should be less than the previous tick");
            assertLt(sqrtPriceX961, sqrtPriceX960, "SqrtPriceX96 should be less than the previous sqrtPriceX96");
        } else {
            assertGt(tick1, tick0, "Tick should be greater than the previous tick");
            assertGt(sqrtPriceX961, sqrtPriceX960, "SqrtPriceX96 should be greater than the previous sqrtPriceX96");
        }
    }
}
