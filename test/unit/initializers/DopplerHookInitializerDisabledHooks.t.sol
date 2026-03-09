// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { Airlock } from "src/Airlock.sol";
import { BaseMinimalHook } from "src/base/BaseMinimalHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

contract DopplerHookInitializerDisabledHooksTest is Deployers {
    Airlock internal airlock;
    DopplerHookInitializer internal initializer;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(makeAddr("airlockOwner"));
        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );

        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));
    }

    function test_afterInitialize_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.afterInitialize(address(this), _poolKey(), 0, 0);
    }

    function test_afterInitialize_RevertsWhenPoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseMinimalHook.HookNotImplemented.selector);
        initializer.afterInitialize(address(this), _poolKey(), 0, 0);
    }

    function test_beforeAddLiquidity_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.beforeAddLiquidity(address(this), _poolKey(), _modifyLiquidityParams(), new bytes(0));
    }

    function test_beforeAddLiquidity_RevertsWhenPoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseMinimalHook.HookNotImplemented.selector);
        initializer.beforeAddLiquidity(address(this), _poolKey(), _modifyLiquidityParams(), new bytes(0));
    }

    function test_beforeRemoveLiquidity_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.beforeRemoveLiquidity(address(this), _poolKey(), _modifyLiquidityParams(), new bytes(0));
    }

    function test_beforeRemoveLiquidity_RevertsWhenPoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseMinimalHook.HookNotImplemented.selector);
        initializer.beforeRemoveLiquidity(address(this), _poolKey(), _modifyLiquidityParams(), new bytes(0));
    }

    function test_beforeDonate_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.beforeDonate(address(this), _poolKey(), 0, 0, new bytes(0));
    }

    function test_beforeDonate_RevertsWhenPoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseMinimalHook.HookNotImplemented.selector);
        initializer.beforeDonate(address(this), _poolKey(), 0, 0, new bytes(0));
    }

    function test_afterDonate_RevertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.afterDonate(address(this), _poolKey(), 0, 0, new bytes(0));
    }

    function test_afterDonate_RevertsWhenPoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseMinimalHook.HookNotImplemented.selector);
        initializer.afterDonate(address(this), _poolKey(), 0, 0, new bytes(0));
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(initializer))
        });
    }

    function _modifyLiquidityParams() internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({ tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0) });
    }
}
