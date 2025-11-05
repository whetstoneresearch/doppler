// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { BaseDook, SenderNotInitializer, SenderNotHook } from "src/base/BaseDook.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

contract DookMock is BaseDook {
    constructor(address initializer, address hook) BaseDook(initializer, hook) { }
}

contract BaseDookTest is Test {
    DookMock baseDook;

    address initializer = makeAddr("initializer");
    address hook = makeAddr("hook");

    function setUp() public {
        baseDook = new DookMock(initializer, hook);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(baseDook.INITIALIZER(), initializer);
        assertEq(baseDook.HOOK(), hook);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        baseDook.onInitialization(address(0), new bytes(0));
    }

    function test_onInitialization_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        baseDook.onInitialization(address(0), new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                 onGraduation()                                 */
    /* ------------------------------------------------------------------------------ */

    function test_onGraduation_RevertsWhenMsgSenderNotInitializer() public {
        vm.expectRevert(SenderNotInitializer.selector);
        baseDook.onGraduation(address(0), new bytes(0));
    }

    function test_onGraduation_PassesWhenMsgSenderInitializer() public {
        vm.prank(initializer);
        baseDook.onGraduation(address(0), new bytes(0));
    }

    /* ------------------------------------------------------------------------------ */
    /*                                    onSwap()                                    */
    /* ------------------------------------------------------------------------------ */

    function test_onSwap_RevertsWhenMsgSenderNotHook() public {
        vm.expectRevert(SenderNotHook.selector);
        baseDook.onSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            new bytes(0)
        );
    }

    function test_onSwap_PassesWhenMsgSenderHook() public {
        vm.prank(hook);
        baseDook.onSwap(
            address(0),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            IPoolManager.SwapParams(false, 0, 0),
            new bytes(0)
        );
    }
}
