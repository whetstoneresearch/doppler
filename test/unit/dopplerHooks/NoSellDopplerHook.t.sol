// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import { NoSellDopplerHook, SellsNotAllowed } from "src/dopplerHooks/NoSellDopplerHook.sol";

contract NoSellDopplerHookTest is Test {
    using PoolIdLibrary for PoolKey;

    NoSellDopplerHook internal dopplerHook;
    address internal initializer = makeAddr("initializer");

    function setUp() public {
        dopplerHook = new NoSellDopplerHook(initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                  constructor()                                   */
    /* -------------------------------------------------------------------------------- */

    function test_constructor_SetsInitializer() public view {
        assertEq(dopplerHook.INITIALIZER(), initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_RevertsWhenSenderNotInitializer(address asset, PoolKey calldata poolKey) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));
    }

    function test_onInitialization_StoresIsAssetToken0_WhenAssetIsToken0(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(poolKey.currency0);
        PoolId poolId = poolKey.toId();

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        assertTrue(dopplerHook.isAssetToken0(poolId));
    }

    function test_onInitialization_StoresIsAssetToken0_WhenAssetIsToken1(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(poolKey.currency1);
        PoolId poolId = poolKey.toId();

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        assertFalse(dopplerHook.isAssetToken0(poolId));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                    onSwap()                                      */
    /* -------------------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSenderNotInitializer(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onSwap_AllowsBuy_WhenAssetIsToken0(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        // Asset is token0, so buying asset means zeroForOne = false (selling token1 for token0)
        address asset = Currency.unwrap(poolKey.currency0);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Buy: zeroForOne = false (getting token0/asset by giving token1/numeraire)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(initializer);
        (Currency feeCurrency, int128 feeAmount) = dopplerHook.onSwap(
            address(0x123),
            poolKey,
            swapParams,
            toBalanceDelta(int128(1e18), int128(-1e18)), // got token0, gave token1
            new bytes(0)
        );

        // Should succeed without revert, returning zero fee
        assertEq(Currency.unwrap(feeCurrency), address(0));
        assertEq(feeAmount, 0);
    }

    function test_onSwap_AllowsBuy_WhenAssetIsToken1(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        // Asset is token1, so buying asset means zeroForOne = true (selling token0 for token1)
        address asset = Currency.unwrap(poolKey.currency1);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Buy: zeroForOne = true (getting token1/asset by giving token0/numeraire)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(initializer);
        (Currency feeCurrency, int128 feeAmount) = dopplerHook.onSwap(
            address(0x123),
            poolKey,
            swapParams,
            toBalanceDelta(int128(-1e18), int128(1e18)), // gave token0, got token1
            new bytes(0)
        );

        // Should succeed without revert, returning zero fee
        assertEq(Currency.unwrap(feeCurrency), address(0));
        assertEq(feeAmount, 0);
    }

    function test_onSwap_RevertsSell_WhenAssetIsToken0(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        // Asset is token0, so selling asset means zeroForOne = true (selling token0 for token1)
        address asset = Currency.unwrap(poolKey.currency0);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Sell: zeroForOne = true (selling token0/asset for token1/numeraire)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.expectRevert(SellsNotAllowed.selector);
        vm.prank(initializer);
        dopplerHook.onSwap(
            address(0x123),
            poolKey,
            swapParams,
            toBalanceDelta(int128(-1e18), int128(1e18)), // gave token0, got token1
            new bytes(0)
        );
    }

    function test_onSwap_RevertsSell_WhenAssetIsToken1(PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        // Asset is token1, so selling asset means zeroForOne = false (selling token1 for token0)
        address asset = Currency.unwrap(poolKey.currency1);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Sell: zeroForOne = false (selling token1/asset for token0/numeraire)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.expectRevert(SellsNotAllowed.selector);
        vm.prank(initializer);
        dopplerHook.onSwap(
            address(0x123),
            poolKey,
            swapParams,
            toBalanceDelta(int128(1e18), int128(-1e18)), // got token0, gave token1
            new bytes(0)
        );
    }

    /* -------------------------------------------------------------------------------- */
    /*                             Fuzz Tests for Swap Logic                            */
    /* -------------------------------------------------------------------------------- */

    function testFuzz_onSwap_AllowsBuys(bool isToken0, PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(isToken0 ? poolKey.currency0 : poolKey.currency1);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Buying asset means:
        // - If asset is token0: zeroForOne = false (sell token1 to get token0)
        // - If asset is token1: zeroForOne = true (sell token0 to get token1)
        bool zeroForOne = !isToken0;

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(initializer);
        (Currency feeCurrency, int128 feeAmount) =
            dopplerHook.onSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));

        // Should succeed without revert
        assertEq(Currency.unwrap(feeCurrency), address(0));
        assertEq(feeAmount, 0);
    }

    function testFuzz_onSwap_RevertsSells(bool isToken0, PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(isToken0 ? poolKey.currency0 : poolKey.currency1);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, new bytes(0));

        // Selling asset means:
        // - If asset is token0: zeroForOne = true (sell token0 to get token1)
        // - If asset is token1: zeroForOne = false (sell token1 to get token0)
        bool zeroForOne = isToken0;

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.expectRevert(SellsNotAllowed.selector);
        vm.prank(initializer);
        dopplerHook.onSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }
}
