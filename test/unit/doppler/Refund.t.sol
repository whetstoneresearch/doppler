// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Position } from "src/Doppler.sol";
import { DERC20 } from "src/DERC20.sol";
import { StateLibrary, IPoolManager, PoolId } from "@v4-core/libraries/StateLibrary.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { SenderNotInitializer, CannotMigrate, MAX_SWAP_FEE } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

contract RefundTest is BaseTest {
    using StateLibrary for IPoolManager;

    function test_refund_SellBackAllTokens() public {
        vm.warp(hook.startingTime());

        // buy half of minimumProceeds In
        (uint256 amountAsset, uint256 amountQuote) = buyExactIn(hook.minimumProceeds() / 2);

        vm.warp(hook.endingTime());

        sellExactIn(1);
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));

        (,,, uint256 totalProceeds,, BalanceDelta feesAccrued) = hook.state();

        console.log("isToken0", isToken0);

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

        sellExactIn(amountAsset);

        assertApproxEqAbs(
            amountDeltaQuote,
            totalProceedsWithFees,
            50,
            "amountDeltaQuote should be equal to totalProceeds + feesAccrued"
        );
        assertApproxEqAbs(amountDeltaAsset, amountAsset, 10_000e18, "amountDelta should be equal to assetBalance");
    }
}
