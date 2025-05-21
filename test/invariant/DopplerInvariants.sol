// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { BaseTest } from "test/shared/BaseTest.sol";
import { DopplerHandler } from "test/invariant/DopplerHandler.sol";
import { State, LOWER_SLUG_SALT } from "src/Doppler.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { DopplerTickLibrary } from "test/utils/DopplerTickLibrary.sol";

contract DopplerInvariantsTest is BaseTest {
    DopplerHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new DopplerHandler(key, hook, router, swapRouter, isToken0, usingEth);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactAmountIn.selector;
        selectors[1] = handler.goNextEpoch.selector;
        selectors[2] = handler.sellExactIn.selector;

        /* selectors[2] = handler.buyExactAmountOut.selector;
        selectors[3] = handler.sellExactOut.selector;
        */

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        excludeSender(address(manager));

        vm.warp(DEFAULT_STARTING_TIME);
    }

    function invariant_TracksTotalTokensSoldAndProceeds() public view {
        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();
        assertEq(totalTokensSold, handler.ghost_totalTokensSold(), "Total tokens sold mismatch");
        assertApproxEqAbs(totalProceeds, handler.ghost_totalProceeds(), 1); //"Total proceeds mismatch");
    }

    function invariant_works() public view { }

    function invariant_CantSellMoreThanNumTokensToSell() public view {
        uint256 numTokensToSell = hook.numTokensToSell();
        assertLe(handler.ghost_totalTokensSold(), numTokensToSell, "Total tokens sold exceeds numTokensToSell");
    }

    function invariant_AlwaysProvidesAllAvailableTokens() public view {
        uint256 numTokensToSell = hook.numTokensToSell();
        uint256 totalTokensProvided;
        uint256 slugs = hook.getNumPDSlugs();

        int24 currentTick = hook.getCurrentTick();

        for (uint256 i = 1; i < 4 + slugs; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity,) = hook.positions(bytes32(uint256(i)));
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtPriceAtTick(currentTick),
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );
            totalTokensProvided += isToken0 ? amount0 : amount1;
        }

        (,, uint256 totalTokensSold,,,) = hook.state();
        assertLe(totalTokensProvided, numTokensToSell - totalTokensSold);
    }

    function invariant_LowerSlugWhenTokensSold() public {
        vm.skip(true);
        (,, uint256 totalTokensSold,,,) = hook.state();
        console.log("Total tokens sold", totalTokensSold);

        // We have to make sure we rebalanced otherwise the invariant will fail
        if (handler.ghost_hasRebalanced()) {
            (,, uint128 liquidity,) = hook.positions(LOWER_SLUG_SALT);

            (int24 tickLower, int24 tickUpper, uint128 liquidity_,) = hook.positions(LOWER_SLUG_SALT);
            assertEq(liquidity, liquidity_, "Lower slug liquidity mismatch");
            assertTrue(liquidity > 0);

            console.log("Lower slug liquidity", liquidity);
            console.log("Total tokens sold", totalTokensSold);
        }
    }

    function invariant_CannotTradeUnderLowerSlug() public view {
        (int24 tickLower,,,) = hook.positions(bytes32(uint256(1)));
        int24 currentTick = hook.getCurrentTick();

        if (isToken0) {
            assertTrue(currentTick >= tickLower);
        } else {
            assertTrue(currentTick <= tickLower);
        }
    }

    function invariant_PositionsDifferentTicks() public view {
        uint256 slugs = hook.getNumPDSlugs();
        for (uint256 i = 1; i < 4 + slugs; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity,) = hook.positions(bytes32(uint256(i)));
            if (liquidity > 0) assertTrue(tickLower != tickUpper);
        }
    }

    function invariant_NoIdenticalRanges() public view {
        uint256 slugs = hook.getNumPDSlugs();
        for (uint256 i = 1; i < 4 + slugs; i++) {
            for (uint256 j = i + 1; j < 4 + slugs - 1; j++) {
                (int24 tickLower0, int24 tickUpper0, uint128 liquidity0,) = hook.positions(bytes32(uint256(i)));
                (int24 tickLower1, int24 tickUpper1, uint128 liquidity1,) = hook.positions(bytes32(uint256(j)));

                if (liquidity0 > 0 && liquidity1 > 0) {
                    assertTrue(
                        tickLower0 != tickLower1 && tickUpper0 != tickUpper1, "Two positions have the same range"
                    );
                }
            }
        }
    }

    // FIXME: This test fails because `goNextEpoch()` can increase the timestamp and start the auction
    function invariant_NoPriceChangesBeforeStart() public {
        vm.skip(true);
        vm.warp(DEFAULT_STARTING_TIME - 1);
        (,,, int24 tickSpacing,) = hook.poolKey();

        assertEq(
            DopplerTickLibrary.alignComputedTickWithTickSpacing(hook.isToken0(), hook.getCurrentTick(), tickSpacing),
            hook.startingTick()
        );
    }

    function invariant_TickChangeCannotExceedGamma() public view {
        int24 change = isToken0 ? hook.startingTick() - hook.endingTick() : hook.endingTick() - hook.startingTick();
        assertLe(hook.gamma() * int24(uint24(hook.getCurrentEpoch())), change, "Tick change exceeds gamma");
    }

    function invariant_EpochsAdvanceWithTime() public view {
        assertEq(hook.getCurrentEpoch(), handler.ghost_currentEpoch(), "Current epoch mismatch");
    }
}
