// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { CannotDonate } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract BeforeDonateTest is BaseTest {
    function test_beforeDonate_RevertsWhenPoolManager() public {
        vm.prank(address(hook.poolManager()));
        vm.expectRevert(CannotDonate.selector);
        hook.beforeDonate(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            0,
            0,
            new bytes(0)
        );
    }

    function test_beforeDonate_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeDonate(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            0,
            0,
            new bytes(0)
        );
    }
}
