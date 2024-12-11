pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { BaseHook } from "v4-periphery/src/base/hooks/BaseHook.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { Unauthorized } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract BeforeAddLiquidityTest is BaseTest {
    // =========================================================================
    //                      beforeAddLiquidity Unit Tests
    // =========================================================================

    function testBeforeAddLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(this),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000,
                tickUpper: 100_000,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function testBeforeAddLiquidity_ReturnsSelectorForHookCaller() public {
        vm.prank(address(manager));
        bytes4 selector = hook.beforeAddLiquidity(
            address(hook),
            key,
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

    function testBeforeAddLiquidity_RevertsForNonHookCaller() public {
        vm.prank(address(manager));
        vm.expectRevert(Unauthorized.selector);
        hook.beforeAddLiquidity(
            address(0xBEEF),
            key,
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
