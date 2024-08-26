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
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

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

    function testBeforeSwap_DoesNotRebalanceBeforeStartTime() public {
        for (uint256 i; i < dopplers.length; ++i) {
            vm.warp(dopplers[i].getStartingTime() - 1); // 1 second before the start time

            PoolKey memory poolKey = keys[i];

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
                uint256 tickAccumulator,
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
                uint256 tickAccumulator,
                uint256 totalTokensSold,
                uint256 totalProceeds,
                uint256 totalTokensSoldLastEpoch
            ) = dopplers[i].state();

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
                uint256 tickAccumulator2,
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
                ,
                ,
                ,
            ) = dopplers[i].state();

            assertEq(lastEpoch, 1);

            vm.warp(dopplers[i].getStartingTime() + dopplers[i].getEpochLength()); // Next epoch

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
                lastEpoch,
                ,
                ,
                ,
            ) = dopplers[i].state();

            assertEq(lastEpoch, 2);
        }
    }
}
