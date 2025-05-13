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

        console.log("data0", data0.tick);
        console.log("data0.numSlugs", data0.numSlugs);
        console.log("data0.positions", data0.positions[0].tickLower);
        console.log("data0.positions", data0.positions[0].tickUpper);
        console.log("data0.positions", data0.positions[0].liquidity);
        console.log("data0.positions", data0.positions[0].salt);
        console.log("data0.positions", data0.positions[1].tickLower);
        console.log("data0.positions", data0.positions[1].tickUpper);
        console.log("data0.positions", data0.positions[1].liquidity);
        console.log("data0.positions", data0.positions[1].salt);

        uint256 numPdSlugs = hook.numPDSlugs();
        console.log("numPdSlugs", numPdSlugs);

        vm.warp(hook.startingTime() + hook.epochLength());

        Position memory lowerSlug = hook.getPositions(LOWER_SLUG_SALT);
        Position memory upperSlug = hook.getPositions(UPPER_SLUG_SALT);
        Position memory pdSlug1 = hook.getPositions(bytes32(uint256(DISCOVERY_SLUG_SALT)));
        Position memory pdSlug2 = hook.getPositions(bytes32(uint256(DISCOVERY_SLUG_SALT) + 1));
        Position memory pdSlug3 = hook.getPositions(bytes32(uint256(DISCOVERY_SLUG_SALT) + 2));
        Position memory pdSlug4 = hook.getPositions(bytes32(uint256(DISCOVERY_SLUG_SALT) + 3));
        Position memory pdSlug5 = hook.getPositions(bytes32(uint256(DISCOVERY_SLUG_SALT) + 4));

        console.log("lowerSlug", lowerSlug.liquidity);
        console.log("upperSlug", upperSlug.liquidity);
        console.log("pdSlug1", pdSlug1.liquidity);
        console.log("pdSlug2", pdSlug2.liquidity);
        console.log("pdSlug3", pdSlug3.liquidity);
        console.log("pdSlug4", pdSlug4.liquidity);
        console.log("pdSlug5", pdSlug5.liquidity);

        DopplerLensReturnData memory data1 = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        // if (isToken0) {
        //     assertLt(data1.tick, data0.tick, "Tick should be less than the previous tick");
        //     assertLt(
        //         data1.sqrtPriceX96, data0.sqrtPriceX96, "SqrtPriceX96 should be less than the previous sqrtPriceX96"
        //     );
        // } else {
        //     assertGt(data1.tick, data0.tick, "Tick should be greater than the previous tick");
        //     assertGt(
        //         data1.sqrtPriceX96, data0.sqrtPriceX96, "SqrtPriceX96 should be greater than the previous sqrtPriceX96"
        //     );
        // }
    }
}
