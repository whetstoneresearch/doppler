// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";
import {BaseTest} from "test/shared/BaseTest.sol";
import {DopplerHandler} from "test/invariant/DopplerHandler.sol";
import {State} from "src/Doppler.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

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

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        vm.warp(DEFAULT_STARTING_TIME);
    }

    function afterInvariant() public view {
        console.log("Calls: ", handler.totalCalls());
        console.log("buyExactAmountIn: ", handler.calls(handler.buyExactAmountIn.selector));
        console.log("buyExactAmountOut: ", handler.calls(handler.buyExactAmountOut.selector));
        console.log("sellExactIn: ", handler.calls(handler.sellExactIn.selector));
        console.log("sellExactOut: ", handler.calls(handler.sellExactOut.selector));
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
    function invariant_AlwaysProvidesAllAvailableTokens() public view {
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
}
