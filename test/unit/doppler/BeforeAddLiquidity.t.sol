// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { CannotAddLiquidity } from "src/modules/initializers/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract BeforeAddLiquidityTest is BaseTest {
    // =========================================================================
    //                      beforeAddLiquidity Unit Tests
    // =========================================================================

    function testBeforeAddLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(this),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000, tickUpper: 100_000, liquidityDelta: 100e18, salt: bytes32(0)
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
                tickLower: -100_000, tickUpper: 100_000, liquidityDelta: 100e18, salt: bytes32(0)
            }),
            ""
        );

        assertEq(selector, BaseHook.beforeAddLiquidity.selector);
    }

    function testBeforeAddLiquidity_RevertsForNonHookCaller() public {
        vm.prank(address(manager));
        vm.expectRevert(CannotAddLiquidity.selector);
        hook.beforeAddLiquidity(
            address(0xBEEF),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -100_000, tickUpper: 100_000, liquidityDelta: 100e18, salt: bytes32(0)
            }),
            ""
        );
    }
}
