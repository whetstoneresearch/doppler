// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { DopplerHandler } from "test/invariant/DopplerHandler.sol";
import { State } from "src/Doppler.sol";
import { LiquidityAmounts } from "v4-core/test/utils/LiquidityAmounts.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

/*

 ? totalTokensSold can't underflow
 ? totalProceeds can't underflow
 ? Computed ticks can't under/overflow
 X Amount of asset tokens to be supplied to liquidity positions at once <= numTokensToSell - totalTokensSold
 Likely further have to consider the actual available token balance as dust is lost due to rounding
 Does not attempt to create liquidity positions with equal upper and lower ticks
Leads to divide by zero error (even just in computing the liquidity amount)
Also relevant for just doing relevant math, e.g. retrieving liquidity given an amount can result in a revert
 Cannot trade the price to below the lower slug range
Else it allows for price manipulation
I think this is also a compliance requirement regardless
 Always places a lower slug if totalTokensSold > 0
 Selling all tokens back in to the curve must exceed the available liquidity
 Single tick ranges do not exceed max liquidity per tick
 Cannot modify the price in any way prior to the start time
 */

contract DopplerInvariantsTest is BaseTest {
    DopplerHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new DopplerHandler(key, hook, router, isToken0, usingEth);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactAmountIn.selector;
        selectors[1] = handler.buyExactAmountOut.selector;
        selectors[2] = handler.sellExactIn.selector;
        // selectors[3] = handler.sellExactOut.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        vm.warp(DEFAULT_STARTING_TIME);
    }

    function afterInvariant() public view {
        console.log("+-------------------+-----------------------+");
        console.log("| Function Name     | Calls                 |", handler.totalCalls());
        console.log("+-------------------+-----------------------+");
        console.log("| buyExactAmountIn  |", handler.calls(handler.buyExactAmountIn.selector), "                  |");
        console.log("| buyExactAmountOut |", handler.calls(handler.buyExactAmountOut.selector), "                  |");
        console.log("| sellExactIn       |", handler.calls(handler.sellExactIn.selector), "                    |");
        console.log("| sellExactOut      |", handler.calls(handler.sellExactOut.selector), "                    |");
        console.log("+-------------------+-----------------------+");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TracksTotalTokensSoldAndProceeds() public view {
        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();
        assertEq(totalTokensSold, handler.ghost_totalTokensSold());
        assertEq(totalProceeds, handler.ghost_totalProceeds());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_CantSellMoreThanNumTokensToSell() public view {
        uint256 numTokensToSell = hook.getNumTokensToSell();
        assertLe(handler.ghost_totalTokensSold(), numTokensToSell);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_AlwaysProvidesAllAvailableTokens() public {
        vm.skip(true);
        uint256 numTokensToSell = hook.getNumTokensToSell();
        uint256 totalTokensProvided;
        uint256 slugs = hook.getNumPDSlugs();

        int24 currentTick = hook.getCurrentTick(poolId);

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
        assertEq(totalTokensProvided, numTokensToSell - totalTokensSold);
    }

    function invariant_LowerSlugWhenTokensSold() public {
        vm.skip(true);
        (,, uint256 totalTokensSold,,,) = hook.state();

        if (totalTokensSold > 0) {
            (,, uint128 liquidity,) = hook.positions(bytes32(uint256(1)));
            assertTrue(liquidity > 0);
        }
    }

    function invariant_CannotTradeUnderLowerSlug() public view {
        (int24 tickLower,,,) = hook.positions(bytes32(uint256(1)));
        int24 currentTick = hook.getCurrentTick(poolId);

        if (isToken0) {
            assertTrue(currentTick >= tickLower);
        } else {
            assertTrue(currentTick <= tickLower);
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_PositionsDifferentTicks() public view {
        uint256 slugs = hook.getNumPDSlugs();
        for (uint256 i = 1; i < 4 + slugs; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity,) = hook.positions(bytes32(uint256(i)));
            if (liquidity > 0) assertTrue(tickLower != tickUpper);
        }
    }

    function invariant_NoPriceChangesBeforeStart() public {
        vm.skip(true);
        vm.warp(DEFAULT_STARTING_TIME - 1);
        // TODO: I think this test is broken because we don't set the tick in the constructor.
        assertEq(hook.getCurrentTick(poolId), hook.getStartingTick());
    }
}
