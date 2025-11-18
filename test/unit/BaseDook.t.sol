// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDook, SenderNotInitializer } from "src/base/BaseDook.sol";

contract DookMock is BaseDook {
    constructor(address initializer) BaseDook(initializer) { }
}

contract BaseDookTest is Test {
    BaseDook internal dook;
    PoolKey internal key;
    address internal initializer = makeAddr("initializer");

    function setUp() public {
        dook = BaseDook(new DookMock(initializer));
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dook.INITIALIZER(), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dook.onInitialization(address(0), key, new bytes(0));
    }

    function test_onInitialization_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dook.onInitialization(address(0), key, new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                 onGraduation()                                 */
    /* ------------------------------------------------------------------------------ */

    function test_onGraduation_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dook.onGraduation(address(0), key, new bytes(0));
    }

    function test_onGraduation_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dook.onGraduation(address(0), key, new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                    onSwap()                                    */
    /* ------------------------------------------------------------------------------ */

    function test_onSwap_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dook.onSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            toBalanceDelta(0, 0),
            new bytes(0)
        );
    }

    function test_onSwap_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dook.onSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            toBalanceDelta(0, 0),
            new bytes(0)
        );
    }
}
