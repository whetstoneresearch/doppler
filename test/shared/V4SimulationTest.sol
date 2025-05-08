// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { DopplerLensTest } from "test/unit/DopplerLens.t.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { State } from "src/Doppler.sol";

interface IERC20 {
    function balanceOf(
        address account
    ) external view returns (uint256);
}

using StateLibrary for IPoolManager;

contract V4SimulationTest is DopplerLensTest {
    function test_buy_EmptyFixedEpochs_BuyWithinFixedEpochsUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        // no buys for X epochs
        uint256 emptyEpochs = 5;

        // consecutive buy with same size for Y epochs
        uint256 fixedEpochs = 10;

        // time travel by `emptyEpochs`
        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs);

        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / fixedEpochs + 1; // in case max proceed is not divisible by the number of epochs

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == fixedEpochs - 1) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            } else {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
            }

            console.log("\n-------------- SALE No. %d ------------------", i + 1);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (emptyEpochs + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    // only works with smaller max proceeds
    // function test_buy_FixedBuyUntilMaxProceed() public {
    //     // Go to starting time
    //     vm.warp(hook.startingTime());

    //     (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

    //     console.log("\n-------------- CURRENT CONFIG ------------------");
    //     console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
    //     console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
    //     console.log("ori sqrtPriceX96", oriSqrtPriceX96);
    //     console.log("starting tick", hook.startingTick());
    //     console.log("ending tick", hook.endingTick());
    //     console.log("gamma", hook.gamma());
    //     console.log("\n");
    //     console.log("numeraire ", numeraire);
    //     console.log("asset ", asset);
    //     console.log("isToken0 ", isToken0);
    //     console.log("usingEth ", usingEth);
    //     console.log("total epochs", hook.getTotalEpochs());
    //     console.log("current epoch", hook.getCurrentEpoch());

    //     uint256 buyEthAmount = 0.01 ether;

    //     uint256 totalEthProceeds;
    //     uint256 count;

    //     // consecutive buy with same size in each epoch
    //     while (totalEthProceeds < DEFAULT_MAXIMUM_PROCEEDS) {
    //         (uint256 tokenBought,) = buy(-int256(buyEthAmount));

    //         (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

    //         totalEthProceeds = totalProceeds;

    //         uint160 sqrtPriceX96;
    //         int24 tick;

    //         if (totalEthProceeds + buyEthAmount >= DEFAULT_MAXIMUM_PROCEEDS) {
    //             (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
    //         } else {
    //             (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
    //                 IV4Quoter.QuoteExactSingleParams({
    //                     poolKey: key,
    //                     zeroForOne: !isToken0,
    //                     exactAmount: 1,
    //                     hookData: ""
    //                 })
    //             );
    //         }

    //         console.log("\n-------------- SALE No. %d ------------------", count + 1);
    //         console.log("current epoch", hook.getCurrentEpoch());
    //         console.log("token bought", tokenBought);
    //         console.log("totalTokensSold / circulating supply", totalTokensSold);
    //         console.log("totalProceeds", totalProceeds);
    //         console.log("\n");
    //         console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
    //         console.log("tick(tokenPerOneETH)", tick);
    //         console.log("isEarlyExit", hook.earlyExit());

    //         vm.warp(hook.startingTime() + hook.epochLength() * (count + 1)); // go to next epoch
    //         count++;
    //     }

    //     vm.prank(hook.initializer());
    //     hook.migrate(address(0xbeef));

    //     console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
    //     console.log("ETH migrated: ", address(0xbeef).balance);
    // }

    function test_buy_BuyWithinFixedEpochsUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        uint256 fixedEpochs = 10;

        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / fixedEpochs + 1; // in case max proceed is not divisible by the number of epochs

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
            (uint256 tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == fixedEpochs - 1) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            } else {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
            }

            console.log("\n-------------- SALE No. %d ------------------", i + 1);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }
}
