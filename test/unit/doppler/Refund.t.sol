// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Position } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract RefundTest is BaseTest {
    function test_refund_SellBackAllTokens() public {
        vm.warp(hook.startingTime() + hook.epochLength() * 8);

        // buy half of minimumProceeds In
        (uint256 amountAsset0,) = buyExactIn(0.05 ether);

        vm.warp(hook.startingTime() + hook.epochLength() * 12);

        (uint256 amountAsset1,) = buyExactIn(0.05 ether);

        vm.warp(hook.startingTime() + hook.epochLength() * 16);

        (uint256 amountAsset2,) = buyExactIn(0.05 ether);

        vm.warp(hook.startingTime() + hook.epochLength() * 20);

        (uint256 amountAsset3,) = buyExactIn(0.01 ether);

        sellExactIn(1);
        vm.warp(hook.endingTime());
        sellExactIn(1);

        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));

        (,,, uint256 totalProceeds,, BalanceDelta feesAccrued) = hook.state();

        uint256 amountDeltaAsset = isToken0
            ? SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity,
                false
            )
            : SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity,
                false
            );

        uint256 amountDeltaQuote = isToken0
            ? SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity,
                true
            )
            : SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity,
                true
            );

        console.log("amountDeltaAsset", amountDeltaAsset);
        console.log("amountDeltaQuote", amountDeltaQuote);

        uint256 feesNumeraire =
            isToken0 ? uint256(uint128(feesAccrued.amount1())) : uint256(uint128(feesAccrued.amount0()));

        uint256 totalProceedsWithFees = totalProceeds + feesNumeraire;

        sellExactIn(amountAsset0 + amountAsset1 + amountAsset2 + amountAsset3);

        assertApproxEqAbs(
            amountDeltaQuote,
            totalProceedsWithFees,
            50,
            "amountDeltaQuote should be equal to totalProceeds + feesAccrued"
        );
        assertApproxEqAbs(
            amountDeltaAsset,
            amountAsset0 + amountAsset1 + amountAsset2 + amountAsset3,
            10_000e18,
            "amountDelta should be equal to assetBalance"
        );
    }
}
