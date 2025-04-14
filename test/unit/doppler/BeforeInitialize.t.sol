// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseTest } from "test/shared/BaseTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { MAX_TICK_SPACING, InvalidTickSpacing } from "src/Doppler.sol";

contract BeforeInitializeTest is BaseTest {
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
}
