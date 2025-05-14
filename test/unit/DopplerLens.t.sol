// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseTest } from "test/shared/BaseTest.sol";
import { StateView } from "@v4-periphery/lens/StateView.sol";
import { DopplerLensQuoter, DopplerLensReturnData } from "src/lens/DopplerLens.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { Position, LOWER_SLUG_SALT, UPPER_SLUG_SALT, DISCOVERY_SLUG_SALT } from "src/Doppler.sol";
import "forge-std/console.sol";

contract DopplerLensTest is BaseTest {
    function test_lens_fetches_consistent_ticks() public {
        vm.warp(hook.startingTime());

        bool isToken0 = hook.isToken0();

        DopplerLensReturnData memory data0 = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("data0.tick", data0.tick);
        console.log("data0.amount0", data0.amount0);
        console.log("data0.amount1", data0.amount1);

        vm.warp(hook.startingTime() + hook.epochLength());

        DopplerLensReturnData memory data1 = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        if (isToken0) {
            assertLt(data1.tick, data0.tick, "Tick should be less than the previous tick");
            assertLt(
                data1.sqrtPriceX96, data0.sqrtPriceX96, "SqrtPriceX96 should be less than the previous sqrtPriceX96"
            );
            assertGt(data1.amount0, data0.amount0, "Amount0 should be greater than the previous amount0");
            assertEq(data1.amount1, data0.amount1, "Amount1 should be equal to the previous amount1");
        } else {
            assertGt(data1.tick, data0.tick, "Tick should be greater than the previous tick");
            assertGt(
                data1.sqrtPriceX96, data0.sqrtPriceX96, "SqrtPriceX96 should be greater than the previous sqrtPriceX96"
            );
            assertGt(data1.amount1, data0.amount1, "Amount1 should be greater than the previous amount1");
            assertEq(data1.amount0, data0.amount0, "Amount0 should be equal to the previous amount0");
        }
    }
}
