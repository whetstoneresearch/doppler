/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest} from "test/BaseTest.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

contract InitializeTest is BaseTest {
    function test_intialize_ShouldInitializeAPool() public {
        int24 tick = manager.initialize(
            PoolKey({
                currency0: Currency.wrap(address(__instances__[0].token0)),
                currency1: Currency.wrap(address(__instances__[0].token1)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(__instances__[0].hook))
            }),
            TickMath.getSqrtPriceAtTick(0),
            ""
        );
        assertEq(tick, 0);
    }
}
