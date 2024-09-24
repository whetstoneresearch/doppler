pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SlugVis} from "./SlugVis.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

import {Doppler, Position} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";
import {BaseTest} from "./BaseTest.sol";

contract DopplerTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
    }

    // =========================================================================
    //                          Integration Tests
    // =========================================================================

    function testRevertsBeforeStartTimeAndAfterEndTime() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime() - 1); // 1 second before the start time

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            vm.expectRevert(
                abi.encodeWithSelector(
                    Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(InvalidTime.selector)
                )
            );
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            vm.warp(ghosts()[i].hook.getEndingTime() + 1); // 1 second after the end time

            vm.expectRevert(
                abi.encodeWithSelector(
                    Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(InvalidTime.selector)
                )
            );
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        }
    }

    function testDoesNotRebalanceTwiceInSameEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
                ghosts()[i].hook.state();

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
                ghosts()[i].hook.state();

            // Ensure that state hasn't updated since we're still in the same epoch
            assertEq(lastEpoch, lastEpoch2);
            assertEq(tickAccumulator, tickAccumulator2);
            assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

            // Ensure that we're tracking the amount of tokens sold
            assertEq(totalTokensSold + 1 ether, totalTokensSold2);
        }
    }

    function testUpdatesLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch,,,,) = ghosts()[i].hook.state();

            assertEq(lastEpoch, 1);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (lastEpoch,,,,) = ghosts()[i].hook.state();

            assertEq(lastEpoch, 2);
        }
    }

    function testUpdatesTotalTokensSoldLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = ghosts()[i].hook.state();

            assertEq(totalTokensSold, 2e18);
            assertEq(totalTokensSoldLastEpoch, 1e18);
        }
    }

    function testMaxDutchAuction() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch, 1);
            // We sold 1e18 tokens just now
            assertEq(totalTokensSold, 1e18);
            // Previous epoch didn't exist so no tokens would have been sold at the time
            assertEq(totalTokensSoldLastEpoch, 0);

            // Swap tokens back into the pool, netSold == 0
            swapRouter.swap(
                // Swap asset to numeraire
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(isToken0, -1 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch2,, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch2, 1);
            // We unsold all the previously sold tokens
            assertEq(totalTokensSold2, 0);
            // This is unchanged because we're still referencing the epoch which didn't exist
            assertEq(totalTokensSoldLastEpoch2, 0);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            // We swap again just to trigger the rebalancing logic in the new epoch
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch3, 2);
            // We sold some tokens just now
            assertEq(totalTokensSold3, 1e18);
            // The net sold amount in the previous epoch was 0
            assertEq(totalTokensSoldLastEpoch3, 0);

            // Assert that we reduced the accumulator by the max amount as intended
            int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();
            assertEq(tickAccumulator3, tickAccumulator + maxTickDeltaPerEpoch);

            // Get positions
            Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // Get global lower and upper ticks
            (, int24 tickUpper) =
                ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator3 / 1e18), poolKey.tickSpacing);

            // Get current tick
            PoolId poolId = poolKey.toId();
            (, int24 currentTick,,) = manager.getSlot0(poolId);

            // Slugs must be inline and continuous
            assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
            assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // Lower slug should be unset with ticks at the current price
            assertEq(lowerSlug.tickLower, lowerSlug.tickUpper);
            assertEq(lowerSlug.liquidity, 0);
            assertEq(lowerSlug.tickUpper, currentTick);

            // Upper and price discovery slugs must be set
            assertNotEq(upperSlug.liquidity, 0);
            assertNotEq(priceDiscoverySlug.liquidity, 0);
        }
    }

    function testRelativeDutchAuction() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            // Get the expected amount sold by next epoch
            uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
                ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()
            );

            // We sell half the expected amount
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(
                    !isToken0, int256(expectedAmountSold / 2), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                ),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch, 1);
            // Confirm we sold half the expected amount
            assertEq(totalTokensSold, expectedAmountSold / 2);
            // Previous epoch didn't exist so no tokens would have been sold at the time
            assertEq(totalTokensSoldLastEpoch, 0);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            // We swap again just to trigger the rebalancing logic in the new epoch
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch2, 2);
            // We sold some tokens just now
            assertEq(totalTokensSold2, expectedAmountSold / 2 + 1e18);
            // The net sold amount in the previous epoch half the expected amount
            assertEq(totalTokensSoldLastEpoch2, expectedAmountSold / 2);

            // Assert that we reduced the accumulator by half the max amount as intended
            int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();
            assertEq(tickAccumulator2, tickAccumulator + maxTickDeltaPerEpoch / 2);

            // Get positions
            Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // Get global lower and upper ticks
            (, int24 tickUpper) =
                ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator2 / 1e18), poolKey.tickSpacing);

            // Get current tick
            PoolId poolId = poolKey.toId();
            (, int24 currentTick,,) = manager.getSlot0(poolId);

            // Slugs must be inline and continuous
            assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
            assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // Lower slug upper tick should be at the currentTick
            assertEq(lowerSlug.tickUpper, currentTick);

            // All slugs must be set
            assertNotEq(lowerSlug.liquidity, 0);
            assertNotEq(upperSlug.liquidity, 0);
            assertNotEq(priceDiscoverySlug.liquidity, 0);
        }
    }

    function testOversoldCase() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            // Get the expected amount sold by next epoch
            uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
                ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()
            );

            // We buy 1.5x the expectedAmountSold
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(
                    !isToken0, int256(expectedAmountSold * 3 / 2), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                ),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch, 1);
            // Confirm we sold the 1.5x the expectedAmountSold
            assertEq(totalTokensSold, expectedAmountSold * 3 / 2);
            // Previous epoch references non-existent epoch
            assertEq(totalTokensSoldLastEpoch, 0);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            // Get current tick
            PoolId poolId = poolKey.toId();
            (, int24 currentTick,,) = manager.getSlot0(poolId);

            // We swap again just to trigger the rebalancing logic in the new epoch
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch2, 2);
            // We sold some tokens just now
            assertEq(totalTokensSold2, expectedAmountSold * 3 / 2 + 1e18);
            // The amount sold by the previous epoch
            assertEq(totalTokensSoldLastEpoch2, expectedAmountSold * 3 / 2);

            // Compute expected tick
            int24 expectedTick = ghosts()[i].hook.getStartingTick() + int24(tickAccumulator / 1e18);
            if (isToken0) {
                expectedTick += int24(ghosts()[i].hook.getElapsedGamma());
            } else {
                expectedTick -= int24(ghosts()[i].hook.getElapsedGamma());
            }

            assertEq(tickAccumulator2, tickAccumulator + (int256(expectedTick - currentTick) * 1e18));

            // Get positions
            Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
            Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
            Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

            // Get global lower and upper ticks
            (int24 tickLower, int24 tickUpper) =
                ghosts()[i].hook.getTicksBasedOnState(int24(tickAccumulator2 / 1e18), poolKey.tickSpacing);

            // Get current tick
            (, currentTick,,) = manager.getSlot0(poolId);

            // Slugs must be inline and continuous
            assertEq(lowerSlug.tickLower, tickLower);
            assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
            assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
            assertEq(priceDiscoverySlug.tickUpper, tickUpper);

            // Lower slug upper tick should be at the currentTick
            assertEq(lowerSlug.tickUpper, currentTick);

            // All slugs must be set
            assertNotEq(lowerSlug.liquidity, 0);
            assertNotEq(upperSlug.liquidity, 0);
            assertNotEq(priceDiscoverySlug.liquidity, 0);
        }
    }

    function testFullFlow() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            // Max dutch auction over first few skipped epochs
            // ===============================================

            // Skip to the 4th epoch before the first swap
            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 3);

            // Swap less then expected amount - to be used checked in the next epoch
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch, 4);
            // Confirm we sold 1 ether
            assertEq(totalTokensSold, 1e18);
            // Previous epochs had no sales
            assertEq(totalTokensSoldLastEpoch, 0);

            int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();

            // Assert that we've done three epochs worth of max dutch auctioning
            assertEq(tickAccumulator, maxTickDeltaPerEpoch * 4);

            // TODO: Validate slug placement

            // Relative dutch auction in next epoch
            // ====================================

            // Go to next epoch (5th)
            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 4);

            // Get the expected amount sold by next epoch
            uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
                ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 5
            );

            // Trigger the oversold case by selling more than expected
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(
                    !isToken0, int256(expectedAmountSold), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                ),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch2, 5);
            // Assert that all sales are accounted for
            assertEq(totalTokensSold2, 1e18 + expectedAmountSold);
            // The amount sold in the previous epoch
            assertEq(totalTokensSoldLastEpoch2, 1e18);

            // Assert that we reduced the accumulator by the relative amount of the max dutch auction
            // corresponding to the amount that we're undersold by
            uint256 expectedAmountSold2 = ghosts()[i].hook.getExpectedAmountSold(block.timestamp);
            // Note: We use the totalTokensSold from the previous epoch (1e18) since this logic was executed
            //       before the most recent swap was accounted for (in the after swap)
            assertEq(
                tickAccumulator2,
                tickAccumulator + maxTickDeltaPerEpoch * int256(1e18 - (1e18 * 1e18 / expectedAmountSold2)) / 1e18
            );

            // TODO: Validate slug placement

            // Oversold case triggers correct increase
            // =======================================

            // Go to next epoch (6th)
            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 5);

            // Get current tick
            PoolId poolId = poolKey.toId();
            (, int24 currentTick,,) = manager.getSlot0(poolId);

            // Trigger rebalance
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3) =
                ghosts()[i].hook.state();

            assertEq(lastEpoch3, 6);
            // Assert that all sales are accounted for
            assertEq(totalTokensSold3, 2e18 + expectedAmountSold);
            // The amount sold in the previous epoch
            assertEq(totalTokensSoldLastEpoch3, 1e18 + expectedAmountSold);

            // Compute expected tick
            int24 expectedTick = ghosts()[i].hook.getStartingTick() + int24(tickAccumulator2 / 1e18);
            if (isToken0) {
                expectedTick += int24(ghosts()[i].hook.getElapsedGamma());
            } else {
                expectedTick -= int24(ghosts()[i].hook.getElapsedGamma());
            }

            assertEq(tickAccumulator3, tickAccumulator2 + (int256(expectedTick - currentTick) * 1e18));

            // Swap in third last epoch
            // ========================

            // Go to third last epoch
            vm.warp(
                ghosts()[i].hook.getStartingTime()
                    + ghosts()[i].hook.getEpochLength()
                        * (
                            (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
                                / ghosts()[i].hook.getEpochLength() - 2
                        )
            );

            // Swap some tokens
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            // TODO: Validate slug placement

            // Swap in second last epoch
            // =========================

            // Go to second last epoch
            vm.warp(
                ghosts()[i].hook.getStartingTime()
                    + ghosts()[i].hook.getEpochLength()
                        * (
                            (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
                                / ghosts()[i].hook.getEpochLength() - 1
                        )
            );

            // Swap some tokens
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            // TODO: Validate slug placement

            // Swap all remaining tokens in last epoch
            // =======================================

            // Go to last epoch
            vm.warp(
                ghosts()[i].hook.getStartingTime()
                    + ghosts()[i].hook.getEpochLength()
                        * (
                            (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
                                / ghosts()[i].hook.getEpochLength()
                        )
            );

            uint256 numTokensToSell = ghosts()[i].hook.getNumTokensToSell();
            (,, uint256 totalTokensSold4,,) = ghosts()[i].hook.state();

            // Swap all remaining tokens
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(
                    !isToken0, int256(numTokensToSell - totalTokensSold4), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                ),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            // TODO: Validate slug placement
        }
    }

    function testCannotSwapBelowLowerSlug_AfterInitialization() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            vm.expectRevert(
                abi.encodeWithSelector(
                    Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(SwapBelowRange.selector)
                )
            );
            // Attempt 0 amount swap below lower slug
            swapRouter.swap(
                // Swap asset to numeraire
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(isToken0, 1, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        }
    }

    function testCannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            // Sell some tokens
            swapRouter.swap(
                // Swap numeraire to asset
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            // Swap to trigger lower slug being created
            // Unsell half of sold tokens
            swapRouter.swap(
                // Swap asset to numeraire
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(isToken0, -0.5 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(SwapBelowRange.selector)
                )
            );
            // Unsell beyond remaining tokens, moving price below lower slug
            swapRouter.swap(
                // Swap asset to numeraire
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(isToken0, -0.6 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        }
    }

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.expectRevert(SafeCallback.NotPoolManager.selector);
            ghosts()[i].hook.beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );
        }
    }

    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_revertsIfNotPoolManager() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.expectRevert(SafeCallback.NotPoolManager.selector);
            ghosts()[i].hook.afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(0, 0),
                ""
            );
        }
    }

    // =========================================================================
    //                      beforeAddLiquidity Unit Tests
    // =========================================================================

    function testBeforeAddLiquidity_RevertsIfNotPoolManager() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.expectRevert(SafeCallback.NotPoolManager.selector);
            ghosts()[i].hook.beforeAddLiquidity(
                address(this),
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -100_000,
                    tickUpper: 100_000,
                    liquidityDelta: 100e18,
                    salt: bytes32(0)
                }),
                ""
            );
        }
    }

    function testBeforeAddLiquidity_ReturnsSelectorForHookCaller() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            bytes4 selector = ghosts()[i].hook.beforeAddLiquidity(
                address(ghosts()[i].hook),
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -100_000,
                    tickUpper: 100_000,
                    liquidityDelta: 100e18,
                    salt: bytes32(0)
                }),
                ""
            );

            assertEq(selector, BaseHook.beforeAddLiquidity.selector);
        }
    }

    function testBeforeAddLiquidity_RevertsForNonHookCaller() public {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            vm.prank(address(manager));
            vm.expectRevert(Unauthorized.selector);
            ghosts()[i].hook.beforeAddLiquidity(
                address(0xBEEF),
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -100_000,
                    tickUpper: 100_000,
                    liquidityDelta: 100e18,
                    salt: bytes32(0)
                }),
                ""
            );
        }
    }

    // =========================================================================
    //                   _getExpectedAmountSold Unit Tests
    // =========================================================================

    function testGetExpectedAmountSold_ReturnsExpectedAmountSold(uint64 timePercentage) public {
        vm.assume(timePercentage <= 1e18);

        for (uint256 i; i < ghosts().length; ++i) {
            uint256 timeElapsed =
                (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()) * timePercentage / 1e18;
            uint256 timestamp = ghosts()[i].hook.getStartingTime() + timeElapsed;
            vm.warp(timestamp);

            uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(timestamp);

            assertApproxEqAbs(
                timestamp,
                ghosts()[i].hook.getStartingTime()
                    + (expectedAmountSold * 1e18 / ghosts()[i].hook.getNumTokensToSell())
                        * (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()) / 1e18,
                1
            );
        }
    }

    // =========================================================================
    //                  _getMaxTickDeltaPerEpoch Unit Tests
    // =========================================================================

    function testGetMaxTickDeltaPerEpoch_ReturnsExpectedAmount() public view {
        for (uint256 i; i < ghosts().length; ++i) {
            int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();

            assertApproxEqAbs(
                ghosts()[i].hook.getEndingTick(),
                (
                    (
                        maxTickDeltaPerEpoch
                            * (
                                int256((ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()))
                                    / int256(ghosts()[i].hook.getEpochLength())
                            )
                    ) / 1e18 + ghosts()[i].hook.getStartingTick()
                ),
                1
            );
        }
    }

    // =========================================================================
    //                   _getElapsedGamma Unit Tests
    // =========================================================================

    function testGetElapsedGamma_ReturnsExpectedAmountSold(uint8 timePercentage) public {
        vm.assume(timePercentage <= 100);
        vm.assume(timePercentage > 0);

        for (uint256 i; i < ghosts().length; ++i) {
            uint256 timeElapsed =
                (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()) * timePercentage / 100;
            uint256 timestamp = ghosts()[i].hook.getStartingTime() + timeElapsed;
            vm.warp(timestamp);

            int256 elapsedGamma = ghosts()[i].hook.getElapsedGamma();

            assertApproxEqAbs(
                int256(ghosts()[i].hook.getGamma()),
                elapsedGamma * int256(ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime())
                    / int256(timestamp - ghosts()[i].hook.getStartingTime()),
                1
            );
        }
    }

    // =========================================================================
    //                   _getTicksBasedOnState Unit Tests
    // =========================================================================

    // TODO: int16 accumulator might over/underflow with certain states
    //       Consider whether we need to protect against this in the contract or whether it's not a concern
    function testGetTicksBasedOnState_ReturnsExpectedAmountSold(int16 accumulator) public view {
        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            (int24 tickLower, int24 tickUpper) =
                ghosts()[i].hook.getTicksBasedOnState(int24(accumulator), poolKey.tickSpacing);
            int24 gamma = ghosts()[i].hook.getGamma();

            if (ghosts()[i].hook.getStartingTick() > ghosts()[i].hook.getEndingTick()) {
                assertEq(int256(gamma), tickUpper - tickLower);
            } else {
                assertEq(int256(gamma), tickLower - tickUpper);
            }
        }
    }

    // =========================================================================
    //                     _getCurrentEpoch Unit Tests
    // =========================================================================

    function testGetCurrentEpoch_ReturnsCorrectEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());
            uint256 currentEpoch = ghosts()[i].hook.getCurrentEpoch();

            assertEq(currentEpoch, 1);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength());
            currentEpoch = ghosts()[i].hook.getCurrentEpoch();

            assertEq(currentEpoch, 2);

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 2);
            currentEpoch = ghosts()[i].hook.getCurrentEpoch();

            assertEq(currentEpoch, 3);
        }
    }

    // =========================================================================
    //                     _computeLiquidity Unit Tests
    // =========================================================================

    function testComputeLiquidity_IsSymmetric(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
        public
        view
    {
        for (uint256 i; i < ghosts().length; ++i) {}
    }
}

error Unauthorized();
error InvalidTime();
error Wrap__FailedHookCall(address, bytes);
error SwapBelowRange();
