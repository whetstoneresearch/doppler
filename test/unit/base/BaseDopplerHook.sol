// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDopplerHook, SenderNotInitializer } from "src/base/BaseDopplerHook.sol";

contract DopplerHookMock is BaseDopplerHook {
    constructor(address initializer) BaseDopplerHook(initializer) { }
}

contract BaseDopplerHookTest is Test {
    BaseDopplerHook internal dopplerHook;
    PoolKey internal key;
    address internal initializer = makeAddr("initializer");

    function setUp() public {
        dopplerHook = BaseDopplerHook(new DopplerHookMock(initializer));
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dopplerHook.INITIALIZER(), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(address(0), key, new bytes(0));
    }

    function test_onInitialization_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dopplerHook.onInitialization(address(0), key, new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                 onGraduation()                                 */
    /* ------------------------------------------------------------------------------ */

    function test_onGraduation_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onGraduation(address(0), key, new bytes(0));
    }

    function test_onGraduation_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dopplerHook.onGraduation(address(0), key, new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                    onAfterSwap()                                    */
    /* ------------------------------------------------------------------------------ */

    function test_onSwap_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onAfterSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            toBalanceDelta(0, 0),
            new bytes(0)
        );
    }

    function test_onSwap_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        dopplerHook.onAfterSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            toBalanceDelta(0, 0),
            new bytes(0)
        );
    }
}
