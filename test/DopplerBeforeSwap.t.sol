pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

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
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {BaseTest, Instance} from "./BaseTest.sol";

/// @dev forge test -vvv --mc DopplerBeforeSwapTest --via-ir
/// TODO: I duplicated this from the test file just to test this out for now.
contract DopplerBeforeSwapTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    // TODO: get this test to trigger the case in `_rebalance` where `requiredProceeds > totalProceeds_`.
    function testBeforeSwap_RebalanceToken1() public {
        // Deploy a new Doppler with `isToken0 = false`
        Instance memory doppler1;
        doppler1.token0 = ghost().token0; // uses existing tokens
        doppler1.token1 = ghost().token1;
        doppler1.hook = targetHookAddress;
        doppler1.tickSpacing = MIN_TICK_SPACING;
        doppler1.deploy({
            vm: vm,
            poolManager: address(manager),
            timeTilStart: 500 seconds,
            duration: 1 days,
            startTick: -100_000,
            endTick: -200_000,
            epochLength: 1 days,
            gamma: 1_000,
            isToken0: false
        });

        __instances__.push(doppler1);

        vm.warp(ghost().hook.getStartingTime());

        PoolKey memory poolKey = ghost().key();

        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = ghost().hook.beforeSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            ""
        );

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }
}

error Unauthorized();
