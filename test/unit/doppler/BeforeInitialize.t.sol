// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseTest } from "test/shared/BaseTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { MAX_TICK_SPACING, InvalidTickSpacing, AlreadyInitialized, InvalidGamma } from "src/Doppler.sol";

contract BeforeInitializeTest is BaseTest {
    function test_beforeInitialize_RevertsWhenAlreadyInitialized() public {
        assertEq(hook.isInitialized(), true);
        vm.prank(address(hook.poolManager()));
        vm.expectRevert(AlreadyInitialized.selector);
        hook.beforeInitialize(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            0
        );
    }

    function test_beforeInitialize_RevertsWhenInvalidTickSpacing() public {
        hook.resetInitialized();
        vm.prank(address(hook.poolManager()));

        vm.expectRevert(InvalidTickSpacing.selector);
        hook.beforeInitialize(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: MAX_TICK_SPACING + 1,
                hooks: IHooks(address(0))
            }),
            0
        );
    }

    function test_beforeInitialize_RevertsWhenInvalidGamma() public {
        hook.resetInitialized();
        vm.prank(address(hook.poolManager()));

        vm.expectRevert(InvalidGamma.selector);
        hook.beforeInitialize(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 30,
                hooks: IHooks(address(0))
            }),
            0
        );
    }

    function test_beforeInitialize_Initializes() public {
        hook.resetInitialized();
        vm.prank(address(hook.poolManager()));
        hook.beforeInitialize(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0xa)),
                currency1: Currency.wrap(address(0xb)),
                fee: 0,
                tickSpacing: DEFAULT_TICK_SPACING,
                hooks: IHooks(address(0))
            }),
            0
        );
        assertTrue(hook.isInitialized(), "Hook not initialized");
    }
}
