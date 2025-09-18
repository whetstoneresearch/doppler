// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import { UniswapV4MulticurveInitializerHook, OnlyInitializer } from "src/UniswapV4MulticurveInitializerHook.sol";

contract UniswapV4MulticurveInitializerHookTest is Test {
    UniswapV4MulticurveInitializerHook public hook;
    address poolManager = makeAddr("PoolManager");
    address initializer = makeAddr("Migrator");

    PoolKey internal emptyPoolKey;
    IPoolManager.ModifyLiquidityParams internal emptyParams;

    function setUp() public {
        hook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(poolManager, initializer), address(hook));
    }

    /// beforeInitialize ///

    function test_beforeInitialize_RevertsWhenSenderParamNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(0), emptyPoolKey, 0);
    }

    function test_beforeInitialize_RevertsWhenSenderParamNotInitializer() public {
        vm.prank(poolManager);
        vm.expectRevert(OnlyInitializer.selector);
        hook.beforeInitialize(address(0), emptyPoolKey, 0);
    }

    function test_beforeInitialize_PassesWhenSenderParamInitializer() public {
        vm.prank(poolManager);
        hook.beforeInitialize(initializer, emptyPoolKey, 0);
    }

    /// beforeAddLiquidity ///

    function test_beforeAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(0), emptyPoolKey, emptyParams, new bytes(0));
    }

    function test_beforeAddLiquidity_RevertsWhenSenderParamNotInitializer() public {
        vm.prank(poolManager);
        vm.expectRevert(OnlyInitializer.selector);
        hook.beforeAddLiquidity(address(0), emptyPoolKey, emptyParams, new bytes(0));
    }

    function test_beforeAddLiquidity_PassesWhenSenderParamInitializer() public {
        vm.prank(poolManager);
        hook.beforeAddLiquidity(initializer, emptyPoolKey, emptyParams, new bytes(0));
    }

    /// afterAddLiquidity ///

    function test_afterAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterAddLiquidity_PassesWhenMsgSenderPoolManager() public {
        vm.prank(poolManager);
        hook.afterAddLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    /// afterRemoveLiquidity ///

    function test_afterRemoveLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterRemoveLiquidity_PassesWhenMsgSenderPoolManager() public {
        vm.prank(poolManager);
        hook.afterRemoveLiquidity(
            address(0),
            emptyPoolKey,
            emptyParams,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }
}
