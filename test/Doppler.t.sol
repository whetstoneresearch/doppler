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

import {Doppler, SlugData} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";
import {BaseTest} from "./BaseTest.sol";

contract DopplerTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_RevertsBeforeStartTime() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime() - 1); // 1 second before the start time

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            vm.expectRevert(
                abi.encodeWithSelector(
                    Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(BeforeStartTime.selector)
                )
            );
            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        }
    }

    function testBeforeSwap_DoesNotRebalanceTwiceInSameEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (
                uint40 lastEpoch,
                int256 tickAccumulator,
                uint256 totalTokensSold,
                ,
                uint256 totalTokensSoldLastEpoch
            ) = ghosts()[i].hook.state();

            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            (
                uint40 lastEpoch2,
                int256 tickAccumulator2,
                uint256 totalTokensSold2,
                ,
                uint256 totalTokensSoldLastEpoch2
            ) = ghosts()[i].hook.state();

            // Ensure that state hasn't updated since we're still in the same epoch
            assertEq(lastEpoch, lastEpoch2);
            assertEq(tickAccumulator, tickAccumulator2);
            assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

            // Ensure that we're tracking the amount of tokens sold
            assertEq(totalTokensSold + 1 ether, totalTokensSold2);
        }
    }

    function testBeforeSwap_UpdatesLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
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
                // Swap token0 => token1 if token1 is the asset (else vice versa)
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

    function testBeforeSwap_UpdatesTotalTokensSoldLastEpoch() public {
        for (uint256 i; i < ghosts().length; ++i) {
            vm.warp(ghosts()[i].hook.getStartingTime());

            PoolKey memory poolKey = ghosts()[i].key();
            bool isToken0 = ghosts()[i].hook.getIsToken0();

            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
                // If zeroForOne, we use max price limit (else vice versa)
                poolKey,
                IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(true, false),
                ""
            );

            vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

            swapRouter.swap(
                // Swap token0 => token1 if token1 is the asset (else vice versa)
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

    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_CorrectlyTracksTokensSoldAndProceeds(int128 amount0, int128 amount1) public {
        // Since we below initialize the values to type(int128).max, we need to ensure that the minimum
        // value used is strictly greater than type(int128).min because type(int128).min is -(type(int128).max + 1)
        vm.assume(amount0 > type(int128).min && amount1 > type(int128).min);

        for (uint256 i; i < ghosts().length; ++i) {
            PoolKey memory poolKey = ghosts()[i].key();

            // Initialize totalTokensSold and totalProceeds as type(int128).max to prevent underflows
            // which can't occur in the actual implementation
            bytes4 selector;
            int128 hookDelta;
            if (ghosts()[i].hook.getIsToken0()) {
                vm.prank(address(manager));
                (selector, hookDelta) = ghosts()[i].hook.afterSwap(
                    address(this),
                    poolKey,
                    IPoolManager.SwapParams({
                        zeroForOne: true,
                        amountSpecified: 100e18,
                        sqrtPriceLimitX96: SQRT_RATIO_2_1
                    }),
                    toBalanceDelta(type(int128).max, -type(int128).max),
                    ""
                );
            } else {
                vm.prank(address(manager));
                (selector, hookDelta) = ghosts()[i].hook.afterSwap(
                    address(this),
                    poolKey,
                    IPoolManager.SwapParams({
                        zeroForOne: true,
                        amountSpecified: 100e18,
                        sqrtPriceLimitX96: SQRT_RATIO_2_1
                    }),
                    toBalanceDelta(type(int128).max, -type(int128).max),
                    ""
                );
            }

            assertEq(selector, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);

            (,, uint256 initialTotalTokensSold, uint256 initialTotalProceeds,) = ghosts()[i].hook.state();

            assertEq(initialTotalTokensSold, uint256(uint128(type(int128).max)));
            assertEq(initialTotalProceeds, uint256(uint128(type(int128).max)));

            vm.prank(address(manager));
            (selector, hookDelta) = ghosts()[i].hook.afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(-amount0, amount1),
                ""
            );
            assertEq(selector, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);

            (,, uint256 totalTokensSold, uint256 totalProceeds,) = ghosts()[i].hook.state();

            if (ghosts()[i].hook.getIsToken0()) {
                // If is token0 then amount0 references the (inverse) amount of tokens sold
                if (amount0 >= 0) {
                    // If is token0 and amount0 is positive, then amount0 is amount of tokens coming back in the pool
                    // i.e. negative sold amount
                    assertEq(totalTokensSold, initialTotalTokensSold - uint256(uint128(amount0)));
                } else {
                    // If is token0 and amount0 is negative, then amount0 is amount of tokens sold
                    // i.e. positive sold amount
                    assertEq(totalTokensSold, initialTotalTokensSold + uint256(uint128(-amount0)));
                }

                // If is token0 then amount1 references the amount of proceeds
                if (amount1 >= 0) {
                    assertEq(totalProceeds, initialTotalProceeds - uint256(uint128(amount1)));
                } else {
                    assertEq(totalProceeds, initialTotalProceeds + uint256(uint128(-amount1)));
                }
            } else {
                // If is token1 then amount1 references the (inverse) amount of tokens sold
                if (amount1 >= 0) {
                    // If is token1 and amount1 is positive, then amount1 is amount of tokens coming back in the pool
                    // i.e. negative sold amount
                    assertEq(totalTokensSold, initialTotalTokensSold - uint256(uint128(amount1)));
                } else {
                    // If is token1 and amount1 is negative, then amount1 is amount of tokens sold
                    // i.e. positive sold amount
                    assertEq(totalTokensSold, initialTotalTokensSold + uint256(uint128(-amount1)));
                }

                // If is token1 then amount0 references the amount of proceeds
                if (amount0 >= 0) {
                    assertEq(totalProceeds, initialTotalProceeds + uint256(uint128(amount0)));
                } else {
                    assertEq(totalProceeds, initialTotalProceeds - uint256(uint128(-amount0)));
                }
            }
        }
    }

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
                                    * int256(ghosts()[i].hook.getEpochLength())
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
            (int24 tickLower, int24 tickUpper) = ghosts()[i].hook.getTicksBasedOnState(int24(accumulator));
            int24 gamma = ghosts()[i].hook.getGamma();

            if (ghosts()[i].hook.getStartingTick() > ghosts()[i].hook.getEndingTick()) {
                assertEq(int256(gamma), tickUpper - tickLower);
            } else {
                assertEq(int256(gamma), tickLower - tickUpper);
            }
        }
    }

    function testComputeLowerSlugData_ReturnsExpectedBounds() public {
        for (uint256 i; i < dopplers.length; ++i) {
            uint256 requiredProceeds = 1e18;
            uint256 totalProceeds = requiredProceeds / 10;
            uint256 totalTokensSold = 10e18;

            bool isToken0 = dopplers[i].getIsToken0();

            vm.prank(address(dopplers[i]));
            SlugData memory slug =
                dopplers[i].computeLowerSlugData(keys[i], requiredProceeds, totalProceeds, totalTokensSold);

            // if the asset is token0, then the target price is the price of token0 in terms of token1
            // i.e. the price of token0 when the proceeds are 1e18
            // expectation is that the tokens are placed near the end of the distribution (endTick)
            // in the token0 case, the endTick is always > startTick
            if (isToken0) {
                uint160 targetPriceX96 = dopplers[i].computeTargetPriceX96(totalProceeds, totalTokensSold);
                int24 tickLower = 2 * TickMath.getTickAtSqrtPrice(targetPriceX96);
                assertEq(slug.tickLower, tickLower);
                assertEq(slug.tickUpper, tickLower + keys[i].tickSpacing);
            } else {
                uint160 targetPriceX96 = dopplers[i].computeTargetPriceX96(totalTokensSold, totalProceeds);
                int24 tickUpper = 2 * TickMath.getTickAtSqrtPrice(targetPriceX96);
                assertEq(slug.tickUpper, tickUpper);
                assertEq(slug.tickLower, tickUpper - keys[i].tickSpacing);
            }
        }
    }

    function testUpperSlugData_ReturnsExpectedBounds() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength());
            bool isToken0 = dopplers[i].getIsToken0();
            uint256 totalTokensSold = 10e18;

            int24 currentTick = dopplers[i].getStartingTick();
            int24 gamma = dopplers[i].getGamma();
            int24 gammaShare = int24(dopplers[i].getGammaShare(block.timestamp + dopplers[i].getEpochLength()) * gamma / 1e18);

            // int256 maxTickDelta = dopplers[i].getMaxTickDeltaPerEpoch();
            // int24 nextTick = int24(maxTickDelta * (int256(block.timestamp - dopplers[i].getStartingTime())) * (int256(dopplers[i].getEpochLength())) / 1e18 + dopplers[i].getStartingTick());
            SlugData memory slug = dopplers[i].computeUpperSlugData(totalTokensSold, currentTick);
            if (isToken0) {
                assertEq(slug.tickLower, currentTick - gammaShare);
                assertEq(slug.tickUpper, currentTick - gammaShare * keys[i].tickSpacing);
            } else {
                assertEq(slug.tickLower, currentTick);
                assertEq(slug.tickUpper, currentTick + gammaShare * keys[i].tickSpacing);
            }
        }
    }

    function testComputePriceDiscoverySlugData_ReturnsExpectedBounds() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength());
            bool isToken0 = dopplers[i].getIsToken0();
            uint256 totalTokensSold = 1e18;

            int24 currentTick = dopplers[i].getStartingTick();
            (int24 tickLower, int24 tickUpper) = dopplers[i].getTicksBasedOnState(0);

            // uint256 epochEndT1 = dopplers[i].getNormalizedTimeElapsed(dopplers[i].getEpochEndWithOffset(0));
            // uint256 epochEndT2 = dopplers[i].getNormalizedTimeElapsed(dopplers[i].getEpochEndWithOffset(1));
            // uint256 epochT1toT2Delta = epochEndT2 - epochEndT1;


            SlugData memory upperSlug = dopplers[i].computeUpperSlugData(totalTokensSold, currentTick);
            SlugData memory pdSlug = dopplers[i].computePriceDiscoverySlugData(upperSlug, tickLower, tickUpper);
            if (isToken0) {
                assertEq(pdSlug.tickLower, upperSlug.tickUpper);
                assertEq(pdSlug.tickUpper, tickLower);
            } else {
                assertEq(pdSlug.tickLower, tickLower);
                assertEq(pdSlug.tickUpper, upperSlug.tickUpper);
            }
        }
    }

    function testComputeSlugs_ReturnsAppropriateSlugStructure() public {
        for (uint256 i; i < dopplers.length; ++i) {
            bool isToken0 = dopplers[i].getIsToken0();
            uint256 requiredProceeds = 1e18;
            uint256 totalProceeds = requiredProceeds / 10;
            uint256 totalTokensSold = 10e18;
            int24 accumulator = 100;

            (int24 tickLower, int24 tickUpper) = dopplers[i].getTicksBasedOnState(accumulator);

            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength());
            int24 startTick = dopplers[i].getStartingTick();
            int24 currentTick = isToken0 ? startTick - 2 * accumulator : startTick + 2 * accumulator;
            console2.logInt(tickLower);
            console2.logInt(tickUpper);

            SlugData memory lowerSlug = dopplers[i].computeLowerSlugData(keys[i], requiredProceeds, totalProceeds, totalTokensSold);
            SlugData memory upperSlug = dopplers[i].computeUpperSlugData(totalTokensSold, currentTick);
            SlugData memory pdSlug = dopplers[i].computePriceDiscoverySlugData(upperSlug, tickLower, tickUpper);

            console2.logInt(lowerSlug.tickLower);
            console2.logInt(lowerSlug.tickUpper);
            console2.logInt(upperSlug.tickLower);
            console2.logInt(upperSlug.tickUpper);
            console2.logInt(pdSlug.tickLower);
            console2.logInt(pdSlug.tickUpper);
        }
    }
}

error Unauthorized();
error BeforeStartTime();
error Wrap__FailedHookCall(address, bytes);
