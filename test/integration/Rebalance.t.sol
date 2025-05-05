// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { stdMath } from "forge-std/StdMath.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { Position, MAX_SWAP_FEE, WAD } from "src/Doppler.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import "forge-std/console.sol";

contract RebalanceTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;
    using stdMath for *;

    function test_rebalance_ExtremeOversoldCase() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;

        // Compute the amount of tokens available in both the upper and price discovery slugs
        // Should be two epochs of liquidity available since we're at the startingTime
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(2);

        // We sell all available tokens
        // This increases the price to the pool maximum
        buy(int256(expectedAmountSold));

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (, int256 tickAccumulator, uint256 totalTokensSold,,,) = hook.state();

        // Get the slugs
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global upper tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // TODO: Depending on the hook, this can hit the insufficient or sufficient proceeds case.
        //       Currently we're hitting insufficient. As such, the assertions should be agnostic
        //       to either case and should only validate that the slugs are placed correctly.
        // TODO: This should also hit the upper slug oversold case and not place an upper slug but
        //       doesn't seem to due to rounding. Consider whether this is a problem or whether we
        //       even need that case at all

        // TODO: Double check this condition

        if (isToken0) {
            // Validate that lower slug is not above the current tick
            assertLe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()), "lowerSlug.tickUpper > currentTick");
        } else {
            // Validate that lower slug is not below the current tick
            assertGe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()), "lowerSlug.tickUpper < currentTick");
        }

        // Validate that upper slug and all price discovery slugs are placed continuously
        assertEq(
            upperSlug.tickUpper,
            priceDiscoverySlugs[0].tickLower,
            "upperSlug.tickUpper != priceDiscoverySlugs[0].tickLower"
        );
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(
                    upperSlug.tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "upperSlug.tickUpper != priceDiscoverySlugs[i].tickLower"
                );
            } else {
                assertEq(
                    priceDiscoverySlugs[i - 1].tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "priceDiscoverySlugs[i - 1].tickUpper != priceDiscoverySlugs[i].tickLower"
                );
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing)),
                    "priceDiscoverySlugs[i].tickUpper != tickUpper"
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0, "priceDiscoverySlugs[i].liquidity is 0");
        }

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 1e18, "lowerSlug no liquidity");

        // Validate that the upper slug has very little liquidity (dust)
        assertLt(upperSlug.liquidity, 1e18, "upperSlug has liquidity");

        // Validate that we can swap all tokens back into the curve
        sell(-int256(totalTokensSold));
    }

    function test_rebalance_LowerSlug_SufficientProceeds() public {
        // We start at the third epoch to allow some dutch auctioning
        vm.warp(hook.startingTime() + hook.epochLength() * 2);

        PoolKey memory poolKey = key;

        // Compute the expected amount sold to see how many tokens will be supplied in the upper slug
        // We should always have sufficient proceeds if we don't swap beyond the upper slug
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // We sell half the expected amount to ensure that we don't surpass the upper slug
        buy(int256(expectedAmountSold / 2));

        (uint40 lastEpoch,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) = hook.state();

        assertEq(lastEpoch, 3);
        // Confirm we sold the correct amount
        assertEq(totalTokensSold, expectedAmountSold / 2);
        // Previous epoch references non-existent epoch
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.startingTime() + hook.epochLength() * 3); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (, int256 tickAccumulator2, uint256 totalTokensSold2,,,) = hook.state();

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));

        // Get global lower tick
        (int24 tickLower,) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Validate that the lower slug is spanning the full range
        if (stdMath.delta(hook.getCurrentTick(poolKey.toId()), tickLower) <= 1) {
            assertEq(
                tickLower + (isToken0 ? -poolKey.tickSpacing : poolKey.tickSpacing),
                lowerSlug.tickLower,
                "lowerSlug.tickLower != global tickLower"
            );
        } else {
            assertEq(tickLower, lowerSlug.tickLower, "lowerSlug.tickUpper != global tickLower");
        }
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "lowerSlug.tickUpper != upperSlug.tickLower");

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 0);

        // Validate that we can swap all tokens back into the curve
        sell(-int256(totalTokensSold2));
    }

    function test_rebalance_LowerSlug_InsufficientProceeds() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.isToken0();

        // Compute the amount of tokens available in both the upper and price discovery slugs
        // Should be two epochs of liquidity available since we're at the startingTime
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(2);

        // We sell 90% of the expected amount so we stay in range but trigger insufficient proceeds case
        buy(int256(expectedAmountSold * 9 / 10));

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1);

        (, int256 tickAccumulator, uint256 totalTokensSold,,,) = hook.state();

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Validate that lower slug is not above the current tick
        isToken0
            ? assertLe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()))
            : assertGe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()));
        if (isToken0) {
            assertEq(
                lowerSlug.tickUpper - lowerSlug.tickLower,
                poolKey.tickSpacing,
                "lowerSlug.tickUpper - lowerSlug.tickLower != poolKey.tickSpacing"
            );
        } else {
            assertEq(
                lowerSlug.tickLower - lowerSlug.tickUpper,
                poolKey.tickSpacing,
                "lowerSlug.tickLower - lowerSlug.tickUpper != poolKey.tickSpacing"
            );
        }

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 0);

        // Validate that upper slug and all price discovery slugs are placed continuously
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(
                    upperSlug.tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "upperSlug.tickUpper != priceDiscoverySlugs[i].tickLower"
                );
            } else {
                assertEq(
                    priceDiscoverySlugs[i - 1].tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "priceDiscoverySlugs[i - 1].tickUpper != priceDiscoverySlugs[i].tickLower"
                );
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing)),
                    "priceDiscoverySlugs[i].tickUpper != tickUpper"
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0, "priceDiscoverySlugs[i].liquidity is 0");
        }

        uint256 amountDelta = isToken0
            ? LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity
            )
            : LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(lowerSlug.tickLower),
                TickMath.getSqrtPriceAtTick(lowerSlug.tickUpper),
                lowerSlug.liquidity
            );

        // assert that the lowerSlug can support the purchase of 99.9% of the tokens sold
        assertApproxEqAbs(amountDelta, totalTokensSold, totalTokensSold * 1 / 1000, "amountDelta != totalTokensSold");
        // TODO: Figure out how this can possibly fail even though the following trade succeeds
        assertGt(amountDelta, totalTokensSold, "amountDelta <= totalTokensSold");

        // Validate that we can swap all tokens back into the curve
        sell(-int256(totalTokensSold));
    }

    function test_rebalance_LowerSlug_NoLiquidity() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        // We sell some tokens to trigger the initial rebalance
        // We haven't sold any tokens in previous epochs so we shouldn't place a lower slug
        buy(1 ether);

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));

        // Assert that lowerSlug ticks are equal and non-zero
        assertEq(lowerSlug.tickLower, lowerSlug.tickUpper);
        assertNotEq(lowerSlug.tickLower, 0);

        // Assert that the lowerSlug has no liquidity
        assertEq(lowerSlug.liquidity, 0);
    }

    function test_big_swap() public {
        vm.warp(hook.startingTime());
        // buy the tokens for epoch 3
        uint256 amountToBuy = hook.getExpectedAmountSoldWithEpochOffset(3);
        buyExactOut(amountToBuy);
        // warp to epoch 3
        vm.warp(hook.startingTime() + hook.epochLength() * 3);
        // get the tick for epoch 3
        (, int24 tickAtEpoch3) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );
        // warp to epoch 6
        vm.warp(hook.startingTime() + hook.epochLength() * 6);
        // get the tick for epoch 6
        (, int24 tickAtEpoch6) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        assertApproxEqAbs(
            tickAtEpoch6,
            isToken0 ? tickAtEpoch3 - 800 * 2 : tickAtEpoch3 + 800 * 2,
            1000,
            "tickAtEpoch6 != tickAtEpoch3 - 800 * 2"
        );
    }

    function test_rebalance_CurrentTick_Correct_After_Each_Rebalance() public {
        vm.warp(hook.startingTime());

        bool isToken0 = hook.isToken0();
        int256 I_WAD = 1e18;

        int256 tickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        (, int24 initialTick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint256 numEpochs = (hook.endingTime() - hook.startingTime()) / hook.epochLength();

        for (uint256 i; i < numEpochs; i++) {
            vm.warp(hook.startingTime() + hook.epochLength() * i);
            if (block.timestamp >= hook.endingTime()) {
                break;
            }

            (, int24 tick) = lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            );
            tick = hook.alignComputedTickWithTickSpacing(tick, key.tickSpacing);

            int24 expectedTick = initialTick + int24((tickDeltaPerEpoch / I_WAD) * int256(i));
            expectedTick = hook.alignComputedTickWithTickSpacing(expectedTick, key.tickSpacing);

            assertEq(tick, expectedTick, string.concat("Failing at epoch ", vm.toString(i + 1)));
        }
    }

    function test_rebalance_UpperSlug_Undersold() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.isToken0();

        // Compute the amount of tokens available in the upper slug
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // We sell half the expected amount to ensure that we hit the undersold case
        buy(int256(expectedAmountSold / 2));

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (, int256 tickAccumulator,,,,) = hook.state();

        // Get the slugs
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower tick
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Validate that the slugs are continuous and all have liquidity
        // TODO: I tried fixing this using isToken0, not sure if it should work this way though.
        if (isToken0) {
            assertEq(
                lowerSlug.tickLower,
                tickLower - poolKey.tickSpacing,
                "tickLower - poolKey.tickSpacing != lowerSlug.tickLower"
            );
        } else {
            assertEq(
                lowerSlug.tickLower,
                tickLower + poolKey.tickSpacing,
                "tickLower + poolKey.tickSpacing != lowerSlug.tickLower"
            );
        }

        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "lowerSlug.tickUpper != upperSlug.tickLower");

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // Validate that all slugs have liquidity
        assertGt(lowerSlug.liquidity, 0, "lowerSlug.liquidity is 0");
        assertGt(upperSlug.liquidity, 0, "upperSlug.liquidity is 0");

        // Validate that the upper slug has the correct range
        uint256 timeDelta = hook.endingTime() - hook.startingTime();
        uint256 normalizedEpochDelta = FullMath.mulDiv(hook.epochLength(), WAD, timeDelta);
        int24 accumulatorDelta = int24(int256(normalizedEpochDelta) * hook.gamma() / 1e18);
        // Explicitly checking that accumulatorDelta is nonzero to show issues with
        // implicit assumption that gamma is positive.
        accumulatorDelta = accumulatorDelta != 0 ? accumulatorDelta : poolKey.tickSpacing;
        // TODO(matt): why are we adding/subtracting the tickSpacing here???
        if (isToken0) {
            assertEq(
                hook.alignComputedTickWithTickSpacing(upperSlug.tickLower + accumulatorDelta, poolKey.tickSpacing)
                    + key.tickSpacing,
                upperSlug.tickUpper,
                "upperSlug.tickUpper != upperSlug.tickLower + accumulatorDelta"
            );
        } else {
            assertEq(
                hook.alignComputedTickWithTickSpacing(upperSlug.tickLower - accumulatorDelta, poolKey.tickSpacing)
                    - poolKey.tickSpacing,
                upperSlug.tickUpper,
                "upperSlug.tickUpper != upperSlug.tickLower - accumulatorDelta"
            );
        }
    }

    // @dev This test only works with a sufficiently high ratio of numPDSlugs / gamma
    //      Not all configurations will trigger this case
    function test_rebalance_UpperSlug_Oversold() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;

        // Compute the amount of tokens available in the upper slug
        uint256 amountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // Compute the amount of tokens available in the price discovery slugs
        uint256 epochT1toT2Delta = hook.getNormalizedTimeElapsed(hook.startingTime() + hook.epochLength())
            - hook.getNormalizedTimeElapsed(hook.startingTime());
        uint256 tokensInPDSlug = FullMath.mulDiv(epochT1toT2Delta, hook.numTokensToSell(), 1e18);
        amountSold += tokensInPDSlug * hook.getNumPDSlugs();

        // We sell all tokens available to trigger the oversold case
        buy(int256(amountSold));

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (, int256 tickAccumulator,,,,) = hook.state();

        // Get the slugs
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global upper tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 0, "lowerSlug.liquidity is 0");

        // Validate that the upper slug doesn't have liquidity
        assertEq(upperSlug.liquidity, 0, "upperSlug.liquidity is non-zero");

        // Validate that the upper slug has a zero range
        assertEq(upperSlug.tickLower, upperSlug.tickUpper, "upperSlug.tickLower != upperSlug.tickUpper");
    }

    function test_rebalance_PriceDiscoverySlug_RemainingEpoch() public {
        // Go to second last epoch
        vm.warp(
            hook.startingTime()
                + hook.epochLength() * ((hook.endingTime() - hook.startingTime()) / hook.epochLength() - 2)
        );

        PoolKey memory poolKey = key;
        bool isToken0 = hook.isToken0();

        // We sell one wei to trigger the rebalance without messing with resulting liquidity positions
        buy(1);

        // Get the upper and price discover slugs
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Assert that the slugs are continuous
        assertApproxEqAbs(
            hook.getCurrentTick(poolKey.toId()), upperSlug.tickLower, 1, "currentTick != upperSlug.tickLower"
        );

        // We should only have one price discovery slug at this point
        assertEq(upperSlug.tickUpper, priceDiscoverySlugs[0].tickLower);

        // Assert that all tokens to sell are in the upper and price discovery slugs.
        // This should be the case since we haven't sold any tokens and we're now
        // at the second last epoch, which means that upper slug should hold all tokens
        // excluding the final epoch worth and price discovery slug should hold the final
        // epoch worth of tokens
        uint256 totalAssetLpSize;
        if (isToken0) {
            totalAssetLpSize += LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
                TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
                upperSlug.liquidity
            );
            totalAssetLpSize += LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(priceDiscoverySlugs[0].tickLower),
                TickMath.getSqrtPriceAtTick(priceDiscoverySlugs[0].tickUpper),
                priceDiscoverySlugs[0].liquidity
            );
        } else {
            totalAssetLpSize += LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
                TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
                upperSlug.liquidity
            );
            totalAssetLpSize += LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(priceDiscoverySlugs[0].tickLower),
                TickMath.getSqrtPriceAtTick(priceDiscoverySlugs[0].tickUpper),
                priceDiscoverySlugs[0].liquidity
            );
        }
        assertApproxEqAbs(totalAssetLpSize, hook.numTokensToSell(), 10_000);
    }

    function testPriceDiscoverySlug_LastEpoch() public {
        // Go to the last epoch
        vm.warp(
            hook.startingTime()
                + hook.epochLength() * ((hook.endingTime() - hook.startingTime()) / hook.epochLength() - 1)
        );

        PoolKey memory poolKey = key;
        bool isToken0 = hook.isToken0();

        // We sell one wei to trigger the rebalance without messing with resulting liquidity positions
        buy(1);

        // Get the upper and price discover slugs
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Assert that the upperSlug is correctly placed
        assertApproxEqAbs(
            hook.getCurrentTick(poolKey.toId()), upperSlug.tickLower, 1, "currentTick != upperSlug.tickLower"
        );

        // Assert that the priceDiscoverySlug has no liquidity
        assertEq(priceDiscoverySlug.liquidity, 0);

        // Assert that all tokens to sell are in the upper and price discovery slugs.
        // This should be the case since we haven't sold any tokens and we're now
        // at the last epoch, which means that upper slug should hold all tokens
        uint256 totalAssetLpSize;
        if (isToken0) {
            totalAssetLpSize += LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
                TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
                upperSlug.liquidity
            );
        } else {
            totalAssetLpSize += LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
                TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
                upperSlug.liquidity
            );
        }
        assertApproxEqAbs(totalAssetLpSize, hook.numTokensToSell(), 10_000);
    }

    function test_rebalance_MaxDutchAuction() public {
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;

        buy(1 ether);

        (uint40 lastEpoch,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) = hook.state();

        assertEq(lastEpoch, 1);
        // We sold 1e18 tokens just now
        assertEq(totalTokensSold, 1e18);
        // Previous epoch didn't exist so no tokens would have been sold at the time
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.startingTime() + hook.epochLength());

        // Swap tokens back into the pool, netSold approxEq 0
        sell(-1 ether + 1);

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        assertEq(lastEpoch2, 2);
        // We unsold all the previously sold tokens, but some of them get taken as fees
        assertApproxEqAbs(totalTokensSold2, 0, MAX_SWAP_FEE * 1e18 / MAX_SWAP_FEE);
        // Total tokens sold previous epoch should be 1 ether
        assertEq(totalTokensSoldLastEpoch2, 1 ether);

        vm.warp(hook.startingTime() + hook.epochLength() * 2); // Next epoch
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3,) =
            hook.state();

        assertEq(lastEpoch3, 3);
        // We sold some tokens just now
        assertApproxEqAbs(totalTokensSold3, 1e18, MAX_SWAP_FEE * 1e18 / MAX_SWAP_FEE);
        // The net sold amount in the previous epoch was 0
        assertApproxEqAbs(totalTokensSoldLastEpoch3, 0, MAX_SWAP_FEE * 1e18 / MAX_SWAP_FEE);

        // Assert that we reduced the accumulator by the max amount as intended
        assertEq(tickAccumulator3, tickAccumulator2 + maxTickDeltaPerEpoch);

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator3, key.tickSpacing);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "lowerSlug.tickUpper != upperSlug.tickLower");

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(
                    priceDiscoverySlugs[i - 1].tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "priceDiscoverySlugs[i - 1].tickUpper != priceDiscoverySlugs[i].tickLower"
                );
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // Upper and price discovery slugs must be set
        assertNotEq(upperSlug.liquidity, 0);
    }

    function test_rebalance_RelativeDutchAuction() public {
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // We sell half the expected amount
        buy(int256(expectedAmountSold / 2));

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) =
            hook.state();

        assertEq(lastEpoch, 1, "Wrong last epoch");
        // Confirm we sold half the expected amount
        assertEq(totalTokensSold, expectedAmountSold / 2, "Wrong tokens sold");
        // Previous epoch didn't exist so no tokens would have been sold at the time
        assertEq(totalTokensSoldLastEpoch, 0, "Wrong tokens sold last epoch");

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        assertEq(lastEpoch2, 2, "Wrong last epoch (2)");
        // We sold some tokens just now
        assertEq(totalTokensSold2, expectedAmountSold / 2 + 1e18, "Wrong tokens sold (2)");
        // The net sold amount in the previous epoch half the expected amount
        assertEq(totalTokensSoldLastEpoch2, expectedAmountSold / 2, "Wrong tokens sold last epoch (2)");

        // Assert that we reduced the accumulator by half the max amount as intended
        assertEq(tickAccumulator2, tickAccumulator + maxTickDeltaPerEpoch / 2, "Wrong tick accumulator");

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Get current tick
        PoolId poolId = poolKey.toId();
        int24 currentTick = hook.getCurrentTick(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "Wrong ticks for lower and upper slugs");

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(
                    upperSlug.tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "Wrong ticks upperSlug.tickUpper / priceDiscoverySlugs[i].tickLower"
                );
            } else {
                assertEq(
                    priceDiscoverySlugs[i - 1].tickUpper,
                    priceDiscoverySlugs[i].tickLower,
                    "Wrong ticks priceDiscoverySlugs[i - 1].tickUpper / priceDiscoverySlugs[i].tickLower"
                );
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0, "Wrong liquidity for price discovery slug");
        }

        // Lower slug upper tick should be at the currentTick
        // use abs because if !istoken0 the tick will be currentTick - 1 because swappingn 1 wei causes us to round down
        assertApproxEqAbs(lowerSlug.tickUpper, currentTick, 1, "lowerSlug.tickUpper not at currentTick");

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0, "lowerSlug.liquidity is 0");
        assertNotEq(upperSlug.liquidity, 0, "upperSlug.liquidity is 0");
    }

    function test_rebalance_OversoldCase() public {
        vm.warp(hook.startingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.isToken0();

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // We buy 1.5x the expectedAmountSold
        buy(int256(expectedAmountSold * 3 / 2));

        (uint40 lastEpoch,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) = hook.state();

        assertEq(lastEpoch, 1);
        // Confirm we sold the 1.5x the expectedAmountSold
        assertEq(totalTokensSold, expectedAmountSold * 3 / 2);
        // Previous epoch references non-existent epoch
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.startingTime() + hook.epochLength()); // Next epoch

        // Get current tick
        PoolId poolId = poolKey.toId();
        int24 currentTick = hook.getCurrentTick(poolId);

        // We swap again just to trigger the rebalancing logic in the new epoch
        buy(1 ether);

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        assertEq(lastEpoch2, 2);
        // We sold some tokens just now
        assertEq(totalTokensSold2, expectedAmountSold * 3 / 2 + 1e18);
        // The amount sold by the previous epoch
        assertEq(totalTokensSoldLastEpoch2, expectedAmountSold * 3 / 2);

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global upper tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);

        // TODO: Depending on the hook used, it's possible to hit the lower slug oversold case or not
        //       Currently we're hitting the oversold case. As such, the assertions should be agnostic
        //       to either case and should only validate that the slugs are placed correctly.

        // Lower slug upper tick must not be greater than the currentTick
        isToken0 ? assertLe(lowerSlug.tickUpper, currentTick) : assertGe(lowerSlug.tickUpper, currentTick);

        // Upper and price discovery slugs must be inline and continuous
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
    }

    function test_rebalance_CollectsFeeFromAllSlugs() public {
        vm.warp(hook.startingTime());

        (,,, uint24 lpFee) = manager.getSlot0(key.toId());

        (,,,,, BalanceDelta feesAccrued) = hook.state();

        BalanceDelta expectedFeesAccrued = toBalanceDelta(0, 0);

        assertTrue(feesAccrued == expectedFeesAccrued);

        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));

        uint256 amount1ToSwap = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
            TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
            upperSlug.liquidity
        ) * 9 / 10;

        uint256 amount0ToSwap = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
            TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
            upperSlug.liquidity
        ) * 9 / 10;

        isToken0 ? buy(-int256(amount1ToSwap)) : buy(-int256(amount0ToSwap));
        isToken0 ? sell(-int256(amount0ToSwap)) : sell(-int256(amount1ToSwap));

        vm.warp(hook.startingTime() + hook.epochLength());

        // trigger rebalance to accrue fees
        buy(1);

        (,,,,, feesAccrued) = hook.state();

        uint256 amount0ExpectedFee;
        uint256 amount1ExpectedFee;

        amount0ExpectedFee = FullMath.mulDiv(amount0ToSwap, lpFee, MAX_SWAP_FEE);
        amount1ExpectedFee = FullMath.mulDiv(amount1ToSwap, lpFee, MAX_SWAP_FEE);

        assertApproxEqAbs(int128(uint128(amount0ExpectedFee)), feesAccrued.amount0(), 1);
        assertApproxEqAbs(int128(uint128(amount1ExpectedFee)), feesAccrued.amount1(), 1);
    }

    function test_rebalance_PdSlugsConvergeToZeroLiquidityAtLastEpoch() public {
        uint256 startTime =
            hook.startingTime() + hook.epochLength() * (hook.getTotalEpochs() - hook.getNumPDSlugs() - 1);
        vm.warp(startTime);

        buy(1 ether);

        // Verify all PD slugs have liquidity initially
        for (uint256 i = 0; i < hook.getNumPDSlugs(); i++) {
            Position memory pdSlug = hook.getPositions(bytes32(uint256(i + 3)));
            assertGt(pdSlug.liquidity, 0, "PD slug should have liquidity initially");
        }

        // Move forward one epoch at a time until the end
        for (uint256 i = 0; i < hook.getNumPDSlugs(); i++) {
            vm.warp(startTime + hook.epochLength() * (i + 1));

            buy(1 ether);

            // Check that slugs from index 2+getNumPdSlugs()-i to the end have 0 liquidity
            for (uint256 j = 0; j < i + 1; j++) {
                Position memory pdSlug = hook.getPositions(bytes32(uint256(2 + hook.getNumPDSlugs() - j)));
                assertEq(pdSlug.liquidity, 0, "PD slug should have 0 liquidity");
            }
        }
    }

    function test_rebalance_totalEpochs() public {
        vm.warp(hook.endingTime() - 1);
        uint256 epochsRemaining = hook.getTotalEpochs() - hook.getCurrentEpoch();
        assertEq(epochsRemaining, 0, "epochsRemaining != 0");
    }

    function test_rebalance_FullFlow() public {
        PoolKey memory poolKey = key;

        // Max dutch auction over first few skipped epochs
        // ===============================================

        // Skip to the 4th epoch before the first swap
        vm.warp(hook.startingTime() + hook.epochLength() * 3);

        // Swap less then expected amount - to be used checked in the next epoch

        buy(1 ether);

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) =
            hook.state();

        assertEq(lastEpoch, 4, "first swap: lastEpoch != 4");
        // Confirm we sold 1 ether
        assertEq(totalTokensSold, 1e18, "first swap: totalTokensSold != 1e18");
        // Previous epochs had no sales
        assertEq(totalTokensSoldLastEpoch, 0, "first swap: totalTokensSoldLastEpoch != 0");

        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        // Assert that we've done three epochs worth of max dutch auctioning
        assertEq(tickAccumulator, maxTickDeltaPerEpoch * 3, "first swap: tickAccumulator != maxTickDeltaPerEpoch * 3");

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Get current tick
        PoolId poolId = poolKey.toId();
        int24 currentTick = hook.getCurrentTick(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "first swap: lowerSlug.tickUpper != upperSlug.tickLower");

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing)),
                    "first swap: priceDiscoverySlugs[i].tickUpper != tickUpper"
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // Lower slug should be unset with ticks at the current price
        assertEq(lowerSlug.tickLower, lowerSlug.tickUpper, "first swap: lowerSlug.tickLower != lowerSlug.tickUpper");
        assertEq(lowerSlug.liquidity, 0, "first swap: lowerSlug.liquidity != 0");
        assertApproxEqAbs(lowerSlug.tickUpper, currentTick, 1, "first swap: lowerSlug.tickUpper != currentTick");

        // Upper and price discovery slugs must be set
        assertNotEq(upperSlug.liquidity, 0, "first swap: upperSlug.liquidity != 0");

        // Relative dutch auction in next epoch
        // ====================================

        // Go to next epoch (5th)
        vm.warp(hook.startingTime() + hook.epochLength() * 4);

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSoldWithEpochOffset(1);

        // Trigger the oversold case by selling more than expected
        buy(int256(expectedAmountSold));

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        assertEq(lastEpoch2, 5, "second swap: lastEpoch2 != 5");
        // Assert that all sales are accounted for
        assertEq(
            totalTokensSold2, 1e18 + expectedAmountSold, "second swap: totalTokensSold2 != 1e18 + expectedAmountSold"
        );
        // The amount sold in the previous epoch
        assertEq(totalTokensSoldLastEpoch2, 1e18, "second swap: totalTokensSoldLastEpoch2 != 1e18");

        // Assert that we reduced the accumulator by the relative amount of the max dutch auction
        // corresponding to the amount that we're undersold by
        uint256 expectedAmountSold2 = hook.getExpectedAmountSoldWithEpochOffset(0);
        // Note: We use the totalTokensSold from the previous epoch (1e18) since this logic was executed
        //       before the most recent swap was accounted for (in the after swap)
        assertEq(
            tickAccumulator2,
            tickAccumulator + maxTickDeltaPerEpoch * int256(1e18 - (1e18 * 1e18 / expectedAmountSold2)) / 1e18,
            "second swap: incorrect tickAccumulator update"
        );

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (, tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "second swap: lowerSlug.tickUpper != upperSlug.tickLower");

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing)),
                    "priceDiscoverySlugs[i].tickUpper != tickUpper"
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0, "second swap: lowerSlug.liquidity != 0");
        assertNotEq(upperSlug.liquidity, 0, "second swap: upperSlug.liquidity != 0");

        // Oversold case triggers correct increase
        // =======================================

        // Go to next epoch (6th)
        vm.warp(hook.startingTime() + hook.epochLength() * 5);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);

        // Trigger rebalance
        buy(1 ether);

        (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3,) =
            hook.state();

        assertEq(lastEpoch3, 6, "third swap: lastEpoch3 != 6");
        // Assert that all sales are accounted for
        assertEq(
            totalTokensSold3, 2e18 + expectedAmountSold, "third swap: totalTokensSold3 != 2e18 + expectedAmountSold"
        );
        // The amount sold in the previous epoch
        assertEq(
            totalTokensSoldLastEpoch3,
            1e18 + expectedAmountSold,
            "third swap: totalTokensSoldLastEpoch3 != 1e18 + expectedAmountSold"
        );

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (int24 tickLower, int24 tickUpper2) = hook.getTicksBasedOnState(tickAccumulator3, poolKey.tickSpacing);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);

        if (isToken0) {
            // Lower slug must not be above current tick
            assertLe(lowerSlug.tickUpper, currentTick, "third swap: lowerSlug.tickUpper > currentTick");
        } else {
            // Lower slug must not be below current tick
            assertGe(lowerSlug.tickUpper, currentTick, "third swap: lowerSlug.tickUpper < currentTick");
        }

        // Upper slugs must be inline and continuous
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper2,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing)),
                    "priceDiscoverySlugs[i].tickUpper != tickUpper2"
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0, "third swap: lowerSlug.liquidity != 0");
        assertNotEq(upperSlug.liquidity, 0, "third swap: upperSlug.liquidity != 0");

        // Validate that we can swap all tokens back into the curve
        sell(-int256(totalTokensSold3));

        // Swap in second last epoch
        // ========================

        // Go to second last epoch
        vm.warp(
            hook.startingTime()
                + hook.epochLength() * ((hook.endingTime() - hook.startingTime()) / hook.epochLength() - 2)
        );

        // Swap some tokens
        buy(1 ether);

        (, int256 tickAccumulator4,,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator4, poolKey.tickSpacing);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);

        if (isToken0) {
            // Lower slug must not be greater than current tick
            assertLe(lowerSlug.tickUpper, currentTick, "fourth swap: lowerSlug.tickUpper > currentTick");
        } else {
            // Lower slug must not be less than current tick
            assertGe(lowerSlug.tickUpper, currentTick, "fourth swap: lowerSlug.tickUpper < currentTick");
        }

        // Upper slugs must be inline and continuous
        // In this case we only have one price discovery slug since we're on the second last epoch
        assertEq(upperSlug.tickUpper, priceDiscoverySlugs[0].tickLower);

        // Validate that the price discovery slug has liquidity
        assertGt(priceDiscoverySlugs[0].liquidity, 1e18);

        // All slugs must be set
        assertNotEq(lowerSlug.tickUpper, 0, "fourth swap: lowerSlug.tickUpper != 0");
        assertNotEq(upperSlug.tickUpper, 0, "fourth swap: upperSlug.tickUpper != 0");

        // lower slug liquidity must be 0
        uint24 fee = poolKey.fee;
        // if the fee is not 0 then the lower slug is expected to have nonzero liquidity
        if (fee == 0) {
            assertEq(lowerSlug.liquidity, 0, "fourth swap: lowerSlug.liquidity != 0");
        }

        // Swap in last epoch
        // =========================

        // Go to last epoch
        vm.warp(
            hook.startingTime()
                + hook.epochLength() * ((hook.endingTime() - hook.startingTime()) / hook.epochLength() - 1)
        );

        // Swap some tokens
        buy(1 ether);

        (, int256 tickAccumulator5,,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator5, poolKey.tickSpacing);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);

        // Slugs must be inline and continuous
        if (stdMath.delta(currentTick, tickLower) <= 1) {
            if (isToken0) {
                assertEq(
                    tickLower - poolKey.tickSpacing,
                    lowerSlug.tickLower,
                    "fifth swap: lowerSlug.tickLower != global tickLower"
                );
            } else {
                assertEq(
                    tickLower + poolKey.tickSpacing,
                    lowerSlug.tickLower,
                    "fifth swap: lowerSlug.tickUpper != global tickLower"
                );
            }
        } else {
            assertEq(tickLower, lowerSlug.tickLower, "fifth swap: lowerSlug.tickUpper != global tickLower");
        }
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "fifth swap: lowerSlug.tickUpper != upperSlug.tickLower");

        // We don't set a priceDiscoverySlug because it's the last epoch
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            // Validate that each price discovery slug has no liquidity
            assertEq(priceDiscoverySlugs[i].liquidity, 0);
        }

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0, "fifth swap: lowerSlug.liquidity != 0");
        assertNotEq(upperSlug.liquidity, 0, "fifth swap: upperSlug.liquidity != 0");

        // Swap all remaining tokens at the end of the last epoch
        // ======================================================

        // Go to very end time
        vm.warp(
            hook.startingTime() + hook.epochLength() * ((hook.endingTime() - hook.startingTime()) / hook.epochLength())
                - 1
        );

        uint256 numTokensToSell = hook.numTokensToSell();
        (,, uint256 totalTokensSold4,,,) = hook.state();

        uint256 feesAccrued =
            uint256(int256(isToken0 ? hook.getFeesAccrued().amount0() : hook.getFeesAccrued().amount1()));

        // Swap all remaining tokens
        // we subtract 50 to account for rounding errors
        buy(int256(numTokensToSell - totalTokensSold4 - feesAccrued - 100));

        (, int256 tickAccumulator6,,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator6, poolKey.tickSpacing);

        // Get current tick
        currentTick = hook.getCurrentTick(poolId);
        assertEq(tickLower, lowerSlug.tickLower, "sixth swap: lowerSlug.tickLower != global tickLower");
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower, "sixth swap: lowerSlug.tickUpper != upperSlug.tickLower");

        // We don't set a priceDiscoverySlug because it's the last epoch
        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            // Validate that each price discovery slug has no liquidity
            assertEq(priceDiscoverySlugs[i].liquidity, 0);
        }

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0, "sixth swap: lowerSlug.liquidity != 0");
        assertNotEq(upperSlug.liquidity, 0, "sixth swap: upperSlug.liquidity != 0");
    }
}
