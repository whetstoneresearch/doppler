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

import {Doppler} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";

contract DopplerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    DopplerImplementation doppler0 = DopplerImplementation(
        address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG))
    );
    PoolKey key0;
    PoolId id0;

    // We create arrays of implementations to test multiple variations at once
    DopplerImplementation[] dopplers;
    PoolKey[] keys;
    PoolId[] ids;

    function setUp() public {
        token0 = new TestERC20(2 ** 128);
        token1 = new TestERC20(2 ** 128);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        manager = new PoolManager(500000);

        vm.warp(1000);

        vm.record();
        DopplerImplementation impl0 = new DopplerImplementation(
            address(manager),
            100_000e18,
            1_500, // 500 seconds from now
            1_500 + 86_400, // 1 day from the start time
            -100_000,
            -200_000,
            50,
            1_000,
            true, // TODO: Make sure it's consistent with the tick direction
            doppler0
        );
        (, bytes32[] memory writes) = vm.accesses(address(impl0));
        vm.etch(address(doppler0), address(impl0).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(doppler0), slot, vm.load(address(impl0), slot));
            }
        }
        key0 = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            MIN_TICK_SPACING,
            IHooks(address(doppler0))
        );
        id0 = key0.toId();

        // TODO: Add more variations of doppler implementations

        dopplers.push(doppler0);
        keys.push(key0);
        ids.push(id0);
    }

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_DoesNotRebalanceBeforeStartTime() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime() - 1); // 1 second before the start time

            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch,
                int256 tickAccumulator,
                uint256 totalTokensSold,
                uint256 totalProceeds,
                uint256 totalTokensSoldLastEpoch
            ) = dopplers[i].state();

            assertEq(lastEpoch, 0);
            assertEq(tickAccumulator, 0);
            assertEq(totalTokensSold, 0);
            assertEq(totalProceeds, 0);
            assertEq(totalTokensSoldLastEpoch, 0);
        }
    }

    function testBeforeSwap_DoesNotRebalanceTwiceInSameEpoch() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime());

            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch,
                int256 tickAccumulator,
                uint256 totalTokensSold,
                uint256 totalProceeds,
                uint256 totalTokensSoldLastEpoch
            ) = dopplers[i].state();

            vm.prank(address(manager));
            (selector, delta, fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (
                uint40 lastEpoch2,
                int256 tickAccumulator2,
                uint256 totalTokensSold2,
                uint256 totalProceeds2,
                uint256 totalTokensSoldLastEpoch2
            ) = dopplers[i].state();

            // Ensure that state hasn't updated since we're still in the same epoch
            assertEq(lastEpoch, lastEpoch2);
            assertEq(tickAccumulator, tickAccumulator2);
            assertEq(totalTokensSold, totalTokensSold2);
            assertEq(totalProceeds, totalProceeds2);
            assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);
        }
    }

    function testBeforeSwap_UpdatesLastEpoch() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime());

            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (uint40 lastEpoch,,,,) = dopplers[i].state();

            assertEq(lastEpoch, 1);

            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength()); // Next epoch

            vm.prank(address(manager));
            (selector, delta, fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (lastEpoch,,,,) = dopplers[i].state();

            assertEq(lastEpoch, 2);
        }
    }

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            vm.expectRevert(Unauthorized.selector);
            dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );
        }
    }

    function testBeforeSwap_UpdatesTotalTokensSoldLastEpoch() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime());

            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            (bytes4 selector0, int128 hookDelta) = dopplers[i].afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(100e18, -100e18),
                ""
            );

            assertEq(selector0, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);

            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength()); // Next epoch

            vm.prank(address(manager));
            (bytes4 selector1, BeforeSwapDelta delta, uint24 fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector1, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = dopplers[i].state();

            assertEq(totalTokensSold, 100e18);
            assertEq(totalTokensSoldLastEpoch, 100e18);
        }
    }

    // =========================================================================
    //                          afterSwap Unit Tests
    // =========================================================================

    function testAfterSwap_CorrectlyTracksTokensSoldAndProceeds(int128 amount0, int128 amount1) public {
        // Since we below initialize the values to type(int128).max, we need to ensure that the minimum
        // value used is strictly greater than type(int128).min because type(int128).min is -(type(int128).max + 1)
        vm.assume(amount0 > type(int128).min && amount1 > type(int128).min);

        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            // Initialize totalTokensSold and totalProceeds as type(int128).max to prevent underflows
            // which can't occur in the actual implementation
            bytes4 selector;
            int128 hookDelta;
            if (dopplers[i].getIsToken0()) {
                vm.prank(address(manager));
                (selector, hookDelta) = dopplers[i].afterSwap(
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
                (selector, hookDelta) = dopplers[i].afterSwap(
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

            (,, uint256 initialTotalTokensSold, uint256 initialTotalProceeds,) = dopplers[i].state();

            assertEq(initialTotalTokensSold, uint256(uint128(type(int128).max)));
            assertEq(initialTotalProceeds, uint256(uint128(type(int128).max)));

            vm.prank(address(manager));
            (selector, hookDelta) = dopplers[i].afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(-amount0, amount1),
                ""
            );
            assertEq(selector, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);


            (,, uint256 totalTokensSold, uint256 totalProceeds,) = dopplers[i].state();

            if (dopplers[i].getIsToken0()) {
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
        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            vm.expectRevert(Unauthorized.selector);
            dopplers[i].afterSwap(
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
        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            vm.expectRevert(Unauthorized.selector);
            dopplers[i].beforeAddLiquidity(
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
        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            bytes4 selector = dopplers[i].beforeAddLiquidity(
                address(dopplers[i]),
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
        for (uint256 i; i < dopplers.length; ++i) {
            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            vm.expectRevert(Unauthorized.selector);
            dopplers[i].beforeAddLiquidity(
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

        for (uint256 i; i < dopplers.length; ++i) {
            uint256 timeElapsed = (dopplers[i].getEndingTime() - dopplers[i].getStartingTime()) * timePercentage / 1e18;
            uint256 timestamp = dopplers[i].getStartingTime() + timeElapsed;
            vm.warp(timestamp);

            uint256 expectedAmountSold = dopplers[i].getExpectedAmountSold();

            assertApproxEqAbs(
                timestamp,
                dopplers[i].getStartingTime()
                    + (expectedAmountSold * 1e18 / dopplers[i].getNumTokensToSell())
                        * (dopplers[i].getEndingTime() - dopplers[i].getStartingTime()) / 1e18,
                1
            );
        }
    }

    // =========================================================================
    //                  _getMaxTickDeltaPerEpoch Unit Tests
    // =========================================================================

    function testGetMaxTickDeltaPerEpoch_ReturnsExpectedAmount() public view {
        for (uint256 i; i < dopplers.length; ++i) {
            int256 maxTickDeltaPerEpoch = dopplers[i].getMaxTickDeltaPerEpoch();

            assertApproxEqAbs(
                dopplers[i].getEndingTick(),
                ((maxTickDeltaPerEpoch
                    * (int256((dopplers[i].getEndingTime() - dopplers[i].getStartingTime())) 
                        * int256(dopplers[i].getEpochLength()))
                ) / 1e18
                + dopplers[i].getStartingTick()),
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

        for (uint256 i; i < dopplers.length; ++i) {
            uint256 timeElapsed = (dopplers[i].getEndingTime() - dopplers[i].getStartingTime()) * timePercentage / 100;
            uint256 timestamp = dopplers[i].getStartingTime() + timeElapsed;
            vm.warp(timestamp);

            int256 elapsedGamma = dopplers[i].getElapsedGamma();

            assertApproxEqAbs(
                int256(dopplers[i].getGamma()),
                elapsedGamma * int256(dopplers[i].getEndingTime() - dopplers[i].getStartingTime())
                / int256(timestamp - dopplers[i].getStartingTime()),
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
        for (uint256 i; i < dopplers.length; ++i) {
            (int24 tickLower, int24 tickUpper) = dopplers[i].getTicksBasedOnState(int24(accumulator));
            uint256 gamma = dopplers[i].getGamma();

            if (dopplers[i].getStartingTick() > dopplers[i].getEndingTick()) {
                assertEq(
                    int256(gamma),
                    tickUpper - tickLower
                );
            } else {
                assertEq(
                    int256(gamma),
                    tickLower - tickUpper
                );
            }
        }
    }

    function testBeforeSwap_LowerSlugReverts() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime());

            PoolKey memory poolKey = keys[i];

            vm.prank(address(manager));
            // afterSwap where 1e3 numeraire (token1) is sent in and 10e18 asset (token0) is sent out
            (bytes4 selector0, int128 hookDelta) = dopplers[i].afterSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 1e3, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                toBalanceDelta(10e18, -1e3),
                ""
            );

            assertEq(selector0, BaseHook.afterSwap.selector);
            assertEq(hookDelta, 0);

            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength()); // Next epoch

            vm.prank(address(manager));
            (bytes4 selector1, BeforeSwapDelta delta, uint24 fee) = dopplers[i].beforeSwap(
                address(this),
                poolKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e3, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
                ""
            );

            assertEq(selector1, BaseHook.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);

            (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = dopplers[i].state();

            assertEq(totalTokensSold, 10e18);
            assertEq(totalTokensSoldLastEpoch, 10e18);
        }
    }
}

error Unauthorized();
