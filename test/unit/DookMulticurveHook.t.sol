// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import { IDook } from "src/interfaces/IDook.sol";
import { OnlyInitializer, Swap, ModifyLiquidity } from "src/UniswapV4MulticurveInitializerHook.sol";
import { DookMulticurveHook } from "src/DookMulticurveHook.sol";
import { DookMulticurveInitializer, PoolStatus } from "src/DookMulticurveInitializer.sol";

contract DookMulticurveHookTest is Test {
    DookMulticurveHook public hook;
    address poolManager = makeAddr("PoolManager");
    address initializer = makeAddr("Initializer");

    PoolKey internal emptyPoolKey;
    IPoolManager.ModifyLiquidityParams internal emptyParams;

    function setUp() public {
        hook = DookMulticurveHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        deployCodeTo("DookMulticurveHook", abi.encode(poolManager, initializer), address(hook));
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(hook.poolManager()), poolManager);
        assertEq(address(hook.INITIALIZER()), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                beforeInitialize()                                */
    /* -------------------------------------------------------------------------------- */

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

    /* ---------------------------------------------------------------------------------- */
    /*                                beforeAddLiquidity()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_beforeAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(0), emptyPoolKey, emptyParams, new bytes(0));
    }

    function test_beforeAddLiquidity_PassesWhenSenderParamInitializer() public {
        vm.prank(poolManager);
        hook.beforeAddLiquidity(initializer, emptyPoolKey, emptyParams, new bytes(0));
    }

    /* --------------------------------------------------------------------------------- */
    /*                                afterAddLiquidity()                                */
    /* --------------------------------------------------------------------------------- */

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

    function test_afterAddLiquidity_PassesWhenMsgSenderPoolManager(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        vm.expectEmit();
        emit ModifyLiquidity(key, params);

        vm.prank(poolManager);
        hook.afterAddLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* ------------------------------------------------------------------------------------ */
    /*                                afterRemoveLiquidity()                                */
    /* ------------------------------------------------------------------------------------ */

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

    function test_afterRemoveLiquidity_PassesWhenMsgSenderPoolManager(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        vm.expectEmit();
        emit ModifyLiquidity(key, params);

        vm.prank(poolManager);
        hook.afterRemoveLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                beforeSwap()                                */
    /* -------------------------------------------------------------------------- */

    function test_beforeSwap_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(
            address(0),
            emptyPoolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            new bytes(0)
        );
    }

    /// @dev We need to redeclare the function because Solidity can't figure out a selector from a public variable
    function getState(address)
        external
        pure
        returns (address, address, bytes memory, PoolStatus, PoolKey memory, int24)
    { }

    function test_beforeSwap_CallsOnSwapWhenDookSet(
        address asset,
        address dook,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) public {
        vm.mockCall(
            initializer,
            abi.encodeWithSelector(this.getState.selector, asset),
            abi.encode(address(0), dook, new bytes(0), PoolStatus.Locked, key, int24(0))
        );
        vm.prank(initializer);
        hook.setDook(key.toId(), dook);

        vm.mockCall(dook, abi.encodeWithSelector(IDook.onSwap.selector, sender, key, params, data), new bytes(0));
        vm.expectCall(dook, abi.encodeWithSelector(IDook.onSwap.selector, sender, key, params, data));
        vm.prank(poolManager);
        hook.beforeSwap(sender, key, params, data);
    }

    /* ------------------------------------------------------------------------- */
    /*                                afterSwap()                                */
    /* ------------------------------------------------------------------------- */

    function test_afterSwap_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(
            address(0),
            emptyPoolKey,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterSwap_PassesWhenMsgSenderPoolManager(
        address sender,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        int128 balanceDelta0,
        int128 balanceDelta1,
        bytes memory hookData
    ) public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        vm.expectEmit();
        emit Swap(sender, key, key.toId(), params, balanceDelta0, balanceDelta1, hookData);

        vm.prank(poolManager);
        hook.afterSwap(sender, key, params, toBalanceDelta(balanceDelta0, balanceDelta1), hookData);
    }
}
