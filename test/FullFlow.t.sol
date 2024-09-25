pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {Doppler, Position} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";
import {BaseTest, Instance} from "./BaseTest.sol";

contract FullFlowTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
    }

    function doSwap(Instance memory ghost, bool isToken0, int256 amount) internal {
        swapRouter.swap(
            ghost.key(),
            IPoolManager.SwapParams(!isToken0, amount, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function warpToEpoch(Instance memory ghost, uint256 epoch) internal {
        uint256 timestamp = ghost.hook.getStartingTime() + ghost.hook.getEpochLength() * (epoch - 1);
        vm.warp(timestamp);
    }

    function getCurrentTick(Instance memory ghost) internal view returns (int24 currentTick) {
        PoolId poolId = ghost.key().toId();
        (, currentTick,,) = manager.getSlot0(poolId);
    }

    function getExpectedAmountSoldNextEpoch(Instance memory ghost, uint256 epoch) internal view returns (uint256) {
        uint256 timestamp = ghost.hook.getStartingTime() + ghost.hook.getEpochLength() * epoch;
        return ghost.hook.getExpectedAmountSold(timestamp);
    }

    function checkHookState(
        Instance memory ghost,
        uint256 epoch,
        uint256 expectedTotalTokensSold,
        uint256 expectedTokensSoldLastEpoch
    ) internal view {
        (
            uint40 lastEpoch,
            int256 tickAccumulator,
            uint256 totalTokensSold,,
            uint256 totalTokensSoldLastEpoch
        ) = ghost.hook.state();
        assertEq(lastEpoch, epoch);
        assertEq(totalTokensSold, expectedTotalTokensSold);
        assertEq(totalTokensSoldLastEpoch, expectedTokensSoldLastEpoch);

        // Assert that we've done three epochs worth of max dutch auctioning
        int256 maxTickDeltaPerEpoch = ghost.hook.getMaxTickDeltaPerEpoch();
        uint256 expectedAmountSold = totalTokensSoldLastEpoch > 0 ? ghost.hook.getExpectedAmountSold(block.timestamp) : 0;
        console.log("expectedAmountSold", expectedAmountSold);
        int256 expectedTickAccumulator = expectedAmountSold > 0 ? maxTickDeltaPerEpoch * int256(1e18 - (1e18 * 1e18 / expectedAmountSold)) / 1e18 : maxTickDeltaPerEpoch * int256(epoch);
        console.log("expectedTickAccumulator", expectedTickAccumulator);
        console.log("tickAccumulator", tickAccumulator);
        assertEq(tickAccumulator, expectedTickAccumulator);
    }

    function getSlugs(Instance memory ghost)
        internal
        view
        returns (Position memory lowerSlug, Position memory upperSlug, Position memory priceDiscoverySlug)
    {
        lowerSlug = ghost.hook.getPositions(bytes32(uint256(1)));
        upperSlug = ghost.hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = ghost.hook.getPositions(bytes32(uint256(3)));
    }

    function validateSlugs(
        Instance memory ghost
    ) internal {
        (, int256 tickAccumulator,,,) = ghost.hook.state();
        // Get positions
        (Position memory lowerSlug, Position memory upperSlug, Position memory priceDiscoverySlug) = getSlugs(ghost);

        // Get global lower and upper ticks
        (int24 tickLower, int24 tickUpper) = ghost.hook.getTicksBasedOnState(tickAccumulator, ghost.key().tickSpacing);

        // Get current tick
        int24 currentTick = getCurrentTick(ghost);

        // Slugs must be inline and continuous
        validateLowerSlug(ghost, lowerSlug, upperSlug, tickLower, tickUpper);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);
    }

    function validateLowerSlug(
        Instance memory ghost,
        Position memory lowerSlug,
        Position memory upperSlug,
        int24 tickLower,
        int24 tickUpper
    ) internal view {
        (,, uint256 totalTokensSold, uint256 totalProceeds,) = ghost.hook.state();
        if (
            ghost.hook.getRequiredProceeds(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), totalTokensSold
            ) > totalProceeds
        ) {
            int24 expectedTickLower =
                ghost.hook.computeTickAtPrice(ghost.hook.getIsToken0(), totalProceeds, totalTokensSold);
            // console.log("expectedTickLower", expectedTickLower);
            // console.log("lowerSlug.tickLower", lowerSlug.tickLower);
            // console.log("totalProceeds", totalProceeds);
            // console.log("totalTokensSold", totalTokensSold);
            assertEq(lowerSlug.tickLower, expectedTickLower);
            assertEq(lowerSlug.tickUpper, lowerSlug.tickLower + ghost.key().tickSpacing);
        } else {
            assertEq(lowerSlug.tickLower, tickLower);
            assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
        }
    }

    function test_FullFlow() public {
        for (uint256 i; i < ghosts().length; ++i) {
            bool isToken0 = ghosts()[i].hook.getIsToken0();
            // Max dutch auction over first few skipped epochs
            // ===============================================

            // Skip to the 4th epoch before the first swap
            uint256 expectedTotalTokensSold = 0;
            uint256 epoch = 4;
            warpToEpoch(ghosts()[i], epoch);
            // Swap less then expected amount - to be used checked in the next epoch
            uint256 assetSwapped = 1 ether;
            expectedTotalTokensSold += assetSwapped;
            doSwap(ghosts()[i], isToken0, int256(assetSwapped));
            checkHookState(ghosts()[i], epoch, expectedTotalTokensSold, 0);

            // Get positions
            (Position memory lowerSlug, Position memory upperSlug, Position memory priceDiscoverySlug) =
                getSlugs(ghosts()[i]);

            // Get current tick

            // Slugs must be inline and continuous
            validateSlugs(ghosts()[i]);
            // assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            // assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // // Lower slug should be unset with ticks at the current price
            // assertEq(lowerSlug.tickLower, lowerSlug.tickUpper);
            // assertEq(lowerSlug.liquidity, 0);
            // assertEq(lowerSlug.tickUpper, currentTick);

            // // Upper and price discovery slugs must be set
            // assertNotEq(upperSlug.liquidity, 0);
            // assertNotEq(priceDiscoverySlug.liquidity, 0);

            // Relative dutch auction in next epoch
            // ====================================

            // Go to next epoch (5th)
            epoch += 1;
            warpToEpoch(ghosts()[i], epoch);
            // Get the expected amount sold by next epoch
            uint256 expectedAmountSold = getExpectedAmountSoldNextEpoch(ghosts()[i], epoch);
            expectedTotalTokensSold += expectedAmountSold;
            // Trigger the oversold case by selling more than expected
            doSwap(ghosts()[i], isToken0, int256(expectedAmountSold));
            checkHookState(ghosts()[i], epoch, expectedTotalTokensSold, 1e18);

            // Assert that we reduced the accumulator by the relative amount of the max dutch auction
            // corresponding to the amount that we're undersold by
            // uint256 expectedAmountSold2 = ghosts()[i].hook.getExpectedAmountSold(block.timestamp);
            // Note: We use the totalTokensSold from the previous epoch (1e18) since this logic was executed
            //       before the most recent swap was accounted for (in the after swap)
            // assertEq(
            //     tickAccumulator2,
            //     tickAccumulator + maxTickDeltaPerEpoch * int256(1e18 - (1e18 * 1e18 / expectedAmountSold2)) / 1e18
            // );

            // Get positions
            (lowerSlug, upperSlug, priceDiscoverySlug) = getSlugs(ghosts()[i]);

            // Slugs must be inline and continuous
            validateSlugs(ghosts()[i]);
            // assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
            // assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            // assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // // All slugs must be set
            // assertNotEq(lowerSlug.liquidity, 0);
            // assertNotEq(upperSlug.liquidity, 0);
            // assertNotEq(priceDiscoverySlug.liquidity, 0);

            // Oversold case triggers correct increase
            // =======================================

            // Go to next epoch (6th)
            epoch += 1;
            warpToEpoch(ghosts()[i], epoch);
            assetSwapped = 1 ether;
            expectedTotalTokensSold += assetSwapped;
            // Trigger rebalance
            doSwap(ghosts()[i], isToken0, int256(assetSwapped));
            checkHookState(ghosts()[i], epoch, expectedTotalTokensSold, 1e18);

            // assertEq(lastEpoch3, 6);
            // // Assert that all sales are accounted for
            // assertEq(totalTokensSold3, 2e18 + expectedAmountSold);
            // // The amount sold in the previous epoch
            // assertEq(totalTokensSoldLastEpoch3, 1e18 + expectedAmountSold);

            // Compute expected tick
            // int24 expectedTick = ghosts()[i].hook.getStartingTick() + int24(tickAccumulator2 / 1e18);
            // if (isToken0) {
            //     expectedTick += int24(ghosts()[i].hook.getElapsedGamma());
            // } else {
            //     expectedTick -= int24(ghosts()[i].hook.getElapsedGamma());
            // }

            // assertEq(tickAccumulator3, tickAccumulator2 + (int256(expectedTick - currentTick) * 1e18));

            // // Get positions
            // lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            // upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            // priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // // Get global lower and upper ticks
            // (int24 tickLower, int24 tickUpper2) =
            //     ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator3 / 1e18), poolKey.tickSpacing);

            // // Get current tick
            // currentTick = getCurrentTick(ghosts()[i]);

            // // Slugs must be inline and continuous
            // validateLowerSlug(
            //     ghosts()[i], lowerSlug, upperSlug, tickLower, tickUpper2, totalProceeds3, totalTokensSold3
            // );
            // assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            // assertEq(priceDiscoverySlug.tickUpper, tickUpper2);

            // // All slugs must be set
            // assertNotEq(lowerSlug.liquidity, 0);
            // assertNotEq(upperSlug.liquidity, 0);
            // assertNotEq(priceDiscoverySlug.liquidity, 0);

            // // Swap in second last epoch
            // // ========================

            // // Go to second last epoch
            // vm.warp(
            //     ghosts()[i].hook.getStartingTime()
            //         + ghosts()[i].hook.getEpochLength()
            //             * (
            //                 (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
            //                     / ghosts()[i].hook.getEpochLength() - 2
            //             )
            // );

            // // Swap some tokens
            // swapRouter.swap(
            //     // Swap numeraire to asset
            //     // If zeroForOne, we use max price limit (else vice versa)
            //     poolKey,
            //     IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            //     PoolSwapTest.TestSettings(true, false),
            //     ""
            // );

            // (, int256 tickAccumulator4,,,) = ghosts()[i].hook.state();

            // // Get positions
            // lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            // upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            // priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // // Get global lower and upper ticks
            // (tickLower, tickUpper) =
            //     ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator4 / 1e18), poolKey.tickSpacing);

            // // Get current tick
            // currentTick = getCurrentTick(ghosts()[i]);

            // // Slugs must be inline and continuous
            // assertEq(lowerSlug.tickLower, tickLower);
            // assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
            // assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            // assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // // All slugs must be set
            // assertNotEq(lowerSlug.liquidity, 0);
            // assertNotEq(upperSlug.liquidity, 0);
            // assertNotEq(priceDiscoverySlug.liquidity, 0);

            // // Swap in last epoch
            // // =========================

            // // Go to last epoch
            // vm.warp(
            //     ghosts()[i].hook.getStartingTime()
            //         + ghosts()[i].hook.getEpochLength()
            //             * (
            //                 (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
            //                     / ghosts()[i].hook.getEpochLength() - 1
            //             )
            // );

            // // Swap some tokens
            // swapRouter.swap(
            //     // Swap numeraire to asset
            //     // If zeroForOne, we use max price limit (else vice versa)
            //     poolKey,
            //     IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            //     PoolSwapTest.TestSettings(true, false),
            //     ""
            // );

            // (, int256 tickAccumulator5,,,) = ghosts()[i].hook.state();

            // // Get positions
            // lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            // upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            // priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // // Get global lower and upper ticks
            // (tickLower, tickUpper) =
            //     ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator5 / 1e18), poolKey.tickSpacing);

            // // Get current tick
            // currentTick = getCurrentTick(ghosts()[i]);

            // // Slugs must be inline and continuous
            // assertEq(lowerSlug.tickLower, tickLower);
            // assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

            // // We don't set a priceDiscoverySlug because it's the last epoch
            // assertEq(priceDiscoverySlug.liquidity, 0);

            // // All slugs must be set
            // assertNotEq(lowerSlug.liquidity, 0);
            // assertNotEq(upperSlug.liquidity, 0);

            // // Swap all remaining tokens at the end of the last epoch
            // // ======================================================

            // // Go to very end time
            // vm.warp(
            //     ghosts()[i].hook.getStartingTime()
            //         + ghosts()[i].hook.getEpochLength()
            //             * (
            //                 (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
            //                     / ghosts()[i].hook.getEpochLength()
            //             )
            // );

            // uint256 numTokensToSell = ghosts()[i].hook.getNumTokensToSell();
            // (,, uint256 totalTokensSold4,,) = ghosts()[i].hook.state();

            // // Swap all remaining tokens
            // swapRouter.swap(
            //     // Swap numeraire to asset
            //     // If zeroForOne, we use max price limit (else vice versa)
            //     poolKey,
            //     IPoolManager.SwapParams(
            //         !isToken0, int256(numTokensToSell - totalTokensSold4), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            //     ),
            //     PoolSwapTest.TestSettings(true, false),
            //     ""
            // );

            // (, int256 tickAccumulator6,,,) = ghosts()[i].hook.state();

            // // Get positions
            // lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            // upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            // priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // // Get global lower and upper ticks
            // (tickLower, tickUpper) =
            //     ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator6 / 1e18), poolKey.tickSpacing);

            // // Get current tick
            // currentTick = getCurrentTick(ghosts()[i]);

            // // Slugs must be inline and continuous
            // assertEq(lowerSlug.tickLower, tickLower);
            // assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

            // // We don't set a priceDiscoverySlug because it's the last epoch
            // assertEq(priceDiscoverySlug.liquidity, 0);

            // // All slugs must be set
            // assertNotEq(lowerSlug.liquidity, 0);
            // assertNotEq(upperSlug.liquidity, 0);
        }
    }
}
