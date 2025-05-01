// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { DopplerLensTest } from "test/unit/DopplerLens.t.sol";
import { State } from "src/Doppler.sol";

interface IERC20 {
    function balanceOf(
        address account
    ) external view returns (uint256);
}

using StateLibrary for IPoolManager;

contract V4PocTest is DopplerLensTest {
    function test_v4_emptyEpochForHalfSale_ThenBuy1ETH() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 oriTokenBalance = IERC20(asset).balanceOf(address(this));

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);

        // no buys for N epochs
        uint256 skipNumOfEpoch = 45; // 5 hrs
        vm.warp(hook.getStartingTime() + hook.getEpochLength() * skipNumOfEpoch);

        // buyExactOut(1);

        // // quote the price
        // (uint160 quotedSqrtPriceX96, int24 quotedTick) = lensQuoter.quoteDopplerLensData(
        //     IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        // );
        // console.log("epoch 46 quoted sqrtPriceX96", quotedSqrtPriceX96);
        // console.log("epoch 46 tick", quotedTick);

        uint256 tokenBalB4 = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;

        // get expected amount sold for the current epoch
        // uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // NOTE: CHANGE BUY AMOUNT HERE
        (uint256 tokenBought,) = buy(-int256(1 ether));
        // (uint256 tokenBought,) = buy(int256(expectedAmountSold));

        uint256 tokenLeft = IERC20(asset).balanceOf(address(manager));
        uint256 tokenLeftInHook = IERC20(asset).balanceOf(address(hook));
        uint256 tokenBalAfter = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;
        // uint256 ethLeft = address(manager).balance;
        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

        // (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        (uint160 sqrtPriceX96, int24 tick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );
        uint256 tokenPerOneETH = sqrtPriceX96;

        console.log("\n-------------- SALE ------------------");
        console.log("tick", tick);
        console.log("token left in hook", tokenLeftInHook);
        console.log("token left in pool", tokenLeft);
        console.log("token bal b4", tokenBalB4);
        console.log("token bal af", tokenBalAfter);
        console.log("token bought", tokenBought);
        console.log("\n");
        console.log("totalTokensSold / circulating supply", totalTokensSold);
        console.log("totalProceeds", totalProceeds);
        console.log("\n");
        console.log("tokenPerOneETH / sqrtPriceX96", tokenPerOneETH);
        console.log("current epoch", hook.getCurrentEpoch());

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * (skipNumOfEpoch + 1)); // go to next epoch
    }

    function test_v4_buyMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        int256 maximumProceeds = int256(hook.getMaximumProceeds());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 oriTokenBalance = IERC20(asset).balanceOf(address(this));

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // quote the price
        (uint160 quotedSqrtPriceX96, int24 quotedTick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );
        console.log("\n");
        console.log("quoted sqrtPriceX96", quotedSqrtPriceX96);
        console.log("quoted tick", quotedTick);

        uint256 tokenBalB4 = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;

        (uint256 tokenBought,) = buy(-maximumProceeds);

        uint256 tokenLeft = IERC20(asset).balanceOf(address(manager));
        uint256 tokenLeftInHook = IERC20(asset).balanceOf(address(hook));
        uint256 tokenBalAfter = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;
        uint256 ethLeft = address(manager).balance;
        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());

        uint256 tokenPerOneETH = sqrtPriceX96;

        console.log("\n-------------- SALE ------------------");
        console.log("tick", tick);
        console.log("token left in hook", tokenLeftInHook);
        console.log("token left in pool", tokenLeft);
        console.log("token bal b4", tokenBalB4);
        console.log("token bal af", tokenBalAfter);
        console.log("token bought", tokenBought);
        console.log("eth left", ethLeft);
        console.log("\n");
        console.log("totalTokensSold / circulating supply", totalTokensSold);
        console.log("totalProceeds", totalProceeds);
        console.log("\n");
        console.log("tokenPerOneETH/sqrtPriceX96", tokenPerOneETH);
        console.log("isEarlyExit", hook.earlyExit());

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // go to next epoch

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function testFuzz_buy_5EmptyEpoch_DiffSizeUntilMaxProceed(
        uint256 buyEtherAmount,
        uint256 sellEtherAmount,
        uint256 buyBackEtherAmount
    ) public _deployLensQuoter {
        uint256 amount = 1.333 ether;
        buyEtherAmount = bound(buyEtherAmount, amount, amount + 0.05 ether);
        sellEtherAmount = bound(sellEtherAmount, 0.55 ether, amount / 2);
        buyBackEtherAmount = bound(buyBackEtherAmount, 0.55 ether, amount / 2);

        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 oriTokenBalance = IERC20(asset).balanceOf(address(this));

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 skipNumOfEpoch = 5;
        uint256 tradeNum = 10;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * skipNumOfEpoch);

        // consecutive trades in each epoch
        for (uint256 i; i < tradeNum; i++) {
            uint256 tokenBalB4 = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;

            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEtherAmount));
            sellExactIn(sellEtherAmount);
            buyExactOut(buyBackEtherAmount);

            uint256 tokenBalAfter = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;
            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == tradeNum - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bal b4", tokenBalB4);
            console.log("token bal af", tokenBalAfter);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (skipNumOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_45emptyEpoch_45SameSizeUntilMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 totalEpochs = 90;
        uint256 halfOfEpoch = totalEpochs / 2;
        uint256 maxProceed = 13_333e15;
        uint256 buyEthAmount = maxProceed / halfOfEpoch + 1;

        console.log("buyEthAmount", buyEthAmount);

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * halfOfEpoch);

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfEpoch; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == halfOfEpoch - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (halfOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_60sPerEpoch_HalfEmptyEpoch_HalfSameSizeUntilMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 totalEpochs = 360;
        uint256 halfOfEpoch = totalEpochs / 2;
        uint256 maxProceed = 13_333e15;
        uint256 buyEthAmount = maxProceed / halfOfEpoch + 1;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * halfOfEpoch);

        // vm.warp(hook.getStartingTime() + hook.getEpochLength()); // go to next epoch

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfEpoch; i++) {
            uint256 tokenBought;

            // if (i == halfOfEpoch - 1) {
            (tokenBought,) = buy(-int256(buyEthAmount));

            // } else {
            //     (tokenBought,) = buy(-int256(0.0740556 ether));
            //     sellExactIn(tokenBought / 2);
            //     buyExactOut(tokenBought / 2);
            // }

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == halfOfEpoch - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (halfOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_24hrSale_HalfEmptyEpoch_HalfSameSizeUntilMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 totalEpochs = 216;
        uint256 halfOfEpoch = totalEpochs / 2;
        uint256 maxProceed = 13_333e15;
        uint256 buyEthAmount = maxProceed / halfOfEpoch + 1;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * halfOfEpoch);

        // vm.warp(hook.getStartingTime() + hook.getEpochLength()); // go to next epoch

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfEpoch; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == halfOfEpoch - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (halfOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_10hrSale_50ETHProceed_100sPerEpoch_HalfEmptyEpoch_HalfSameSizeUntilMaxProceed()
        public
        _deployLensQuoter
    {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 totalEpochs = 360;
        uint256 halfOfEpoch = totalEpochs / 2;
        uint256 maxProceed = 50 ether;
        uint256 buyEthAmount = maxProceed / halfOfEpoch + 1;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * halfOfEpoch);

        // vm.warp(hook.getStartingTime() + hook.getEpochLength()); // go to next epoch

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfEpoch; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            // if (i == halfOfEpoch - 1) {
            (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            // } else {
            //     (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
            //         IV4Quoter.QuoteExactSingleParams({
            //             poolKey: key,
            //             zeroForOne: !isToken0,
            //             exactAmount: 1,
            //             hookData: ""
            //         })
            //     );
            // }
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (halfOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_60emptyEpoch_30SameSizeUntilMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 skipNumOfEpoch = 60;
        uint256 tradeNum = 30;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * skipNumOfEpoch);

        // consecutive buy in each epoch
        for (uint256 i; i < tradeNum; i++) {
            uint256 tokenBought;

            if (i == tradeNum - 1) {
                (tokenBought,) = buy(-int256(0.44467 ether));
            } else {
                (tokenBought,) = buy(-int256(0.44467 ether));
                sellExactIn(tokenBought / 2);
                buyExactOut(tokenBought / 2);
            }

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == tradeNum - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (skipNumOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_70emptyEpoch_20SameSizeUntilMaxProceed() public _deployLensQuoter {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        (uint160 oriSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.getStartingTick());
        console.log("ending tick", hook.getEndingTick());
        console.log("gamma", hook.getGamma());

        // no buys for N epochs
        uint256 skipNumOfEpoch = 70;
        uint256 tradeNum = 20;

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * skipNumOfEpoch);

        // consecutive buy in each epoch
        for (uint256 i; i < tradeNum; i++) {
            uint256 tokenBought;

            if (i == tradeNum - 1) {
                (tokenBought,) = buy(-int256(0.667 ether));
            } else {
                (tokenBought,) = buy(-int256(0.667 ether));
                sellExactIn(tokenBought / 2);
                buyExactOut(tokenBought / 2);
            }

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == tradeNum - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.getStartingTime() + hook.getEpochLength() * (skipNumOfEpoch + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }
}
