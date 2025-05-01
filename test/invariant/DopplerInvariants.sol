// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseTest } from "test/shared/BaseTest.sol";
import { DopplerHandler } from "test/invariant/DopplerHandler.sol";
import { State } from "src/Doppler.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

contract DopplerInvariantsTest is BaseTest {
    DopplerHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new DopplerHandler(key, hook, router, isToken0, usingEth);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buyExactAmountIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.buyExactAmountOut.selector;
        selectors[3] = handler.sellExactOut.selector;
        selectors[4] = handler.goNextEpoch.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        vm.warp(DEFAULT_STARTING_TIME);
    }

    function invariant_TracksTotalTokensSoldAndProceeds() public view {
        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();
        assertEq(totalTokensSold, handler.ghost_totalTokensSold(), "Total tokens sold mismatch");
        assertEq(totalProceeds, handler.ghost_totalProceeds(), "Total proceeds mismatch");
    }

    function invariant_CantSellMoreThanNumTokensToSell() public view {
        uint256 numTokensToSell = hook.numTokensToSell();
        assertLe(handler.ghost_totalTokensSold(), numTokensToSell, "Total tokens sold exceeds numTokensToSell");
    }

    function invariant_AlwaysProvidesAllAvailableTokens() public view {
        uint256 numTokensToSell = hook.numTokensToSell();
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
        assertLe(totalTokensProvided, numTokensToSell - totalTokensSold);
    }

    function invariant_LowerSlugWhenTokensSold() public view {
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

    function invariant_NoPriceChangesBeforeStart() public {
        vm.warp(DEFAULT_STARTING_TIME - 1);
        assertEq(hook.getCurrentTick(poolId), hook.startingTick());
    }

    function invariant_TickChangeCannotExceedGamma() public view {
        int24 change = isToken0 ? hook.startingTick() - hook.endingTick() : hook.endingTick() - hook.startingTick();
        assertLe(hook.gamma() * int24(uint24(hook.getCurrentEpoch())), change, "Tick change exceeds gamma");
    }

    function invariant_EpochsAdvanceWithTime() public view {
        assertEq(hook.getCurrentEpoch(), handler.ghost_currentEpoch(), "Current epoch mismatch");
    }
}
