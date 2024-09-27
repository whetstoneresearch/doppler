pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {SlugVis} from "test/shared/SlugVis.sol";

import {InvalidTime, SwapBelowRange} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";
import {Position} from "../../src/Doppler.sol";

contract RebalanceTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_rebalance_ExtremeOversoldCase() public {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Compute the amount of tokens available in both the upper and price discovery slugs
        // Should be two epochs of liquidity available since we're at the startingTime
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength() * 2);

        // We sell all available tokens
        // This increases the price to the pool maximum
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

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (, int256 tickAccumulator,,,) = hook.state();

        // Get the slugs
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global upper tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // TODO: Depending on the hook, this can hit the insufficient or sufficient proceeds case.
        //       Currently we're hitting insufficient. As such, the assertions should be agnostic
        //       to either case and should only validate that the slugs are placed correctly.
        // TODO: This should also hit the upper slug oversold case and not place an upper slug but
        //       doesn't seem to due to rounding. Consider whether this is a problem or whether we
        //       even need that case at all

        // Validate that lower slug is not above the current tick
        assertLe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()));

        // Validate that upper slug and price discovery slug are placed continuously
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);

        // Validate that the lower slug and price discovery slug have liquidity
        assertGt(lowerSlug.liquidity, 1e18);
        assertGt(priceDiscoverySlug.liquidity, 1e18);

        // Validate that the upper slug has very little liquidity (dust)
        assertLt(upperSlug.liquidity, 1e18);

        // TODO: Validate that the lower slug has enough liquidity to handle all tokens sold
        //       back into the curve.
    }

    function test_rebalance_LowerSlug_SufficientProceeds() public {
        // We start at the third epoch to allow some dutch auctioning
        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 2);

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Compute the expected amount sold to see how many tokens will be supplied in the upper slug
        // We should always have sufficient proceeds if we don't swap beyond the upper slug
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength() * 3);

        // We sell half the expected amount to ensure that we don't surpass the upper slug
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

        (uint40 lastEpoch,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = hook.state();

        assertEq(lastEpoch, 3);
        // Confirm we sold the correct amount
        assertEq(totalTokensSold, expectedAmountSold / 2);
        // Previous epoch references non-existent epoch
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 3); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (, int256 tickAccumulator2,,,) = hook.state();

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));

        // Get global lower tick
        (int24 tickLower,) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Validate that the lower slug is spanning the full range
        assertEq(tickLower, lowerSlug.tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 0);
    }

    function test_rebalance_LowerSlug_InsufficientProceeds() public {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Compute the amount of tokens available in both the upper and price discovery slugs
        // Should be two epochs of liquidity available since we're at the startingTime
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength() * 2);

        // We sell 90% of the expected amount so we stay in range but trigger insufficient proceeds case
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(
                !isToken0, int256(expectedAmountSold * 9 / 10), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (, int256 tickAccumulator,,,) = hook.state();

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Validate that lower slug is not above the current tick
        assertLe(lowerSlug.tickUpper, hook.getCurrentTick(poolKey.toId()));
        if (isToken0) {
            assertEq(lowerSlug.tickUpper - lowerSlug.tickLower, poolKey.tickSpacing);
        } else {
            assertEq(lowerSlug.tickLower - lowerSlug.tickUpper, poolKey.tickSpacing);
        }

        // Validate that the lower slug has liquidity
        assertGt(lowerSlug.liquidity, 0);

        // Validate that upper slug and price discovery slug are placed continuously
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);
    }

    function test_rebalance_LowerSlug_NoLiquidity() public {
        // Go to starting time
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // We sell some tokens to trigger the initial rebalance
        // We haven't sold any tokens in previous epochs so we shouldn't place a lower slug
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        // Get the lower slug
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));

        // Assert that lowerSlug ticks are equal and non-zero
        assertEq(lowerSlug.tickLower, lowerSlug.tickUpper);
        assertNotEq(lowerSlug.tickLower, 0);

        // Assert that the lowerSlug has no liquidity
        assertEq(lowerSlug.liquidity, 0);
    }

    function test_rebalance_PriceDiscoverySlug_RemainingEpoch() public {
        // Go to second last epoch
        vm.warp(
            hook.getStartingTime()
                + hook.getEpochLength() * ((hook.getEndingTime() - hook.getStartingTime()) / hook.getEpochLength() - 2)
        );

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // We sell one wei to trigger the rebalance without messing with resulting liquidity positions
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        // Get the upper and price discover slugs
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Assert that the slugs are continuous
        assertEq(hook.getCurrentTick(poolKey.toId()), upperSlug.tickLower);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);

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
                TickMath.getSqrtPriceAtTick(priceDiscoverySlug.tickLower),
                TickMath.getSqrtPriceAtTick(priceDiscoverySlug.tickUpper),
                priceDiscoverySlug.liquidity
            );
        } else {
            totalAssetLpSize += LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(upperSlug.tickLower),
                TickMath.getSqrtPriceAtTick(upperSlug.tickUpper),
                upperSlug.liquidity
            );
            totalAssetLpSize += LiquidityAmounts.getAmount1ForLiquidity(
                TickMath.getSqrtPriceAtTick(priceDiscoverySlug.tickLower),
                TickMath.getSqrtPriceAtTick(priceDiscoverySlug.tickUpper),
                priceDiscoverySlug.liquidity
            );
        }
        assertApproxEqAbs(totalAssetLpSize, hook.getNumTokensToSell(), 10_000);
    }

    function testPriceDiscoverySlug_LastEpoch() public {
        // Go to the last epoch
        vm.warp(
            hook.getStartingTime()
                + hook.getEpochLength() * ((hook.getEndingTime() - hook.getStartingTime()) / hook.getEpochLength() - 1)
        );

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // We sell one wei to trigger the rebalance without messing with resulting liquidity positions
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            poolKey,
            IPoolManager.SwapParams(!isToken0, 1, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        // Get the upper and price discover slugs
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Assert that the upperSlug is correctly placed
        assertEq(hook.getCurrentTick(poolKey.toId()), upperSlug.tickLower);

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
        assertApproxEqAbs(totalAssetLpSize, hook.getNumTokensToSell(), 10_000);
    }

    function test_rebalance_MaxDutchAuction() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
            hook.state();

        assertEq(lastEpoch, 1);
        // We sold 1e18 tokens just now
        assertEq(totalTokensSold, 1e18);
        // Previous epoch didn't exist so no tokens would have been sold at the time
        assertEq(totalTokensSoldLastEpoch, 0);

        // Swap tokens back into the pool, netSold == 0
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -1 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch2,, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) = hook.state();

        assertEq(lastEpoch2, 1);
        // We unsold all the previously sold tokens
        assertEq(totalTokensSold2, 0);
        // This is unchanged because we're still referencing the epoch which didn't exist
        assertEq(totalTokensSoldLastEpoch2, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // We swap again just to trigger the rebalancing logic in the new epoch
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3) =
            hook.state();

        assertEq(lastEpoch3, 2);
        // We sold some tokens just now
        assertEq(totalTokensSold3, 1e18);
        // The net sold amount in the previous epoch was 0
        assertEq(totalTokensSoldLastEpoch3, 0);

        // Assert that we reduced the accumulator by the max amount as intended
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();
        assertEq(tickAccumulator3, tickAccumulator + maxTickDeltaPerEpoch);

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator3, key.tickSpacing);

        // Get current tick
        PoolId poolId = key.toId();
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

    function test_rebalance_RelativeDutchAuction() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength());

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
            hook.state();

        assertEq(lastEpoch, 1);
        // Confirm we sold half the expected amount
        assertEq(totalTokensSold, expectedAmountSold / 2);
        // Previous epoch didn't exist so no tokens would have been sold at the time
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

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
            hook.state();

        assertEq(lastEpoch2, 2);
        // We sold some tokens just now
        assertEq(totalTokensSold2, expectedAmountSold / 2 + 1e18);
        // The net sold amount in the previous epoch half the expected amount
        assertEq(totalTokensSoldLastEpoch2, expectedAmountSold / 2);

        // Assert that we reduced the accumulator by half the max amount as intended
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();
        assertEq(tickAccumulator2, tickAccumulator + maxTickDeltaPerEpoch / 2);

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

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

    function test_rebalance_OversoldCase() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength());

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
            hook.state();

        assertEq(lastEpoch, 1);
        // Confirm we sold the 1.5x the expectedAmountSold
        assertEq(totalTokensSold, expectedAmountSold * 3 / 2);
        // Previous epoch references non-existent epoch
        assertEq(totalTokensSoldLastEpoch, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

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
            hook.state();

        assertEq(lastEpoch2, 2);
        // We sold some tokens just now
        assertEq(totalTokensSold2, expectedAmountSold * 3 / 2 + 1e18);
        // The amount sold by the previous epoch
        assertEq(totalTokensSoldLastEpoch2, expectedAmountSold * 3 / 2);

        assertEq(tickAccumulator2, tickAccumulator + int24(hook.getElapsedGamma()));

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global upper tick
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

        // TODO: Depending on the hook used, it's possible to hit the lower slug oversold case or not
        //       Currently we're hitting the oversold case. As such, the assertions should be agnostic
        //       to either case and should only validate that the slugs are placed correctly.

        // Lower slug upper tick must not be greater than the currentTick
        assertLe(lowerSlug.tickUpper, currentTick);

        // Upper and price discovery slugs must be inline and continuous
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
        assertNotEq(priceDiscoverySlug.liquidity, 0);
    }

    function test_rebalance_FullFlow() public {
        PoolKey memory poolKey = key;
        bool isToken0 = hook.getIsToken0();

        // Max dutch auction over first few skipped epochs
        // ===============================================

        // Skip to the 4th epoch before the first swap
        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 3);

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
            hook.state();

        assertEq(lastEpoch, 4);
        // Confirm we sold 1 ether
        assertEq(totalTokensSold, 1e18);
        // Previous epochs had no sales
        assertEq(totalTokensSoldLastEpoch, 0);

        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        // Assert that we've done three epochs worth of max dutch auctioning
        assertEq(tickAccumulator, maxTickDeltaPerEpoch * 4);

        // Get positions
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

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

        // Relative dutch auction in next epoch
        // ====================================

        // Go to next epoch (5th)
        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 4);

        // Get the expected amount sold by next epoch
        uint256 expectedAmountSold = hook.getExpectedAmountSold(hook.getStartingTime() + hook.getEpochLength() * 5);

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
            hook.state();

        assertEq(lastEpoch2, 5);
        // Assert that all sales are accounted for
        assertEq(totalTokensSold2, 1e18 + expectedAmountSold);
        // The amount sold in the previous epoch
        assertEq(totalTokensSoldLastEpoch2, 1e18);

        // Assert that we reduced the accumulator by the relative amount of the max dutch auction
        // corresponding to the amount that we're undersold by
        uint256 expectedAmountSold2 = hook.getExpectedAmountSold(block.timestamp);
        // Note: We use the totalTokensSold from the previous epoch (1e18) since this logic was executed
        //       before the most recent swap was accounted for (in the after swap)
        assertEq(
            tickAccumulator2,
            tickAccumulator + maxTickDeltaPerEpoch * int256(1e18 - (1e18 * 1e18 / expectedAmountSold2)) / 1e18
        );

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (, tickUpper) = hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
        assertNotEq(priceDiscoverySlug.liquidity, 0);

        // Oversold case triggers correct increase
        // =======================================

        // Go to next epoch (6th)
        vm.warp(hook.getStartingTime() + hook.getEpochLength() * 5);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

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
            hook.state();

        assertEq(lastEpoch3, 6);
        // Assert that all sales are accounted for
        assertEq(totalTokensSold3, 2e18 + expectedAmountSold);
        // The amount sold in the previous epoch
        assertEq(totalTokensSoldLastEpoch3, 1e18 + expectedAmountSold);

        // Compute expected tick
        int256 accumulatorDelta = isToken0 ? hook.getElapsedGamma() : -hook.getElapsedGamma();

        assertEq(tickAccumulator3, tickAccumulator2 + accumulatorDelta);

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (int24 tickLower, int24 tickUpper2) = hook.getTicksBasedOnState(tickAccumulator3, poolKey.tickSpacing);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickLower, tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper2);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
        assertNotEq(priceDiscoverySlug.liquidity, 0);

        // Swap in second last epoch
        // ========================

        // Go to second last epoch
        vm.warp(
            hook.getStartingTime()
                + hook.getEpochLength() * ((hook.getEndingTime() - hook.getStartingTime()) / hook.getEpochLength() - 2)
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

        (, int256 tickAccumulator4,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator4, poolKey.tickSpacing);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickLower, tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
        assertNotEq(priceDiscoverySlug.liquidity, 0);

        // Swap in last epoch
        // =========================

        // Go to last epoch
        vm.warp(
            hook.getStartingTime()
                + hook.getEpochLength() * ((hook.getEndingTime() - hook.getStartingTime()) / hook.getEpochLength() - 1)
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

        (, int256 tickAccumulator5,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator5, poolKey.tickSpacing);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickLower, tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

        // We don't set a priceDiscoverySlug because it's the last epoch
        assertEq(priceDiscoverySlug.liquidity, 0);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);

        // Swap all remaining tokens at the end of the last epoch
        // ======================================================

        // Go to very end time
        vm.warp(
            hook.getStartingTime()
                + hook.getEpochLength() * ((hook.getEndingTime() - hook.getStartingTime()) / hook.getEpochLength())
        );

        uint256 numTokensToSell = hook.getNumTokensToSell();
        (,, uint256 totalTokensSold4,,) = hook.state();

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

        (, int256 tickAccumulator6,,,) = hook.state();

        // Get positions
        lowerSlug = hook.getPositions(bytes32(uint256(1)));
        upperSlug = hook.getPositions(bytes32(uint256(2)));
        priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global lower and upper ticks
        (tickLower, tickUpper) = hook.getTicksBasedOnState(tickAccumulator6, poolKey.tickSpacing);

        // Get current tick
        (, currentTick,,) = manager.getSlot0(poolId);

        // Slugs must be inline and continuous
        assertEq(lowerSlug.tickLower, tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

        // We don't set a priceDiscoverySlug because it's the last epoch
        assertEq(priceDiscoverySlug.liquidity, 0);

        // All slugs must be set
        assertNotEq(lowerSlug.liquidity, 0);
        assertNotEq(upperSlug.liquidity, 0);
    }
}
