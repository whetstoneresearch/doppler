// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import {
    InsufficientAmountLeft,
    SwapRestrictorDopplerHook,
    UpdatedAmountLeft
} from "src/dopplerHooks/SwapRestrictorDopplerHook.sol";

contract SwapRestrictorDopplerHookTest is Test {
    SwapRestrictorDopplerHook internal dopplerHook;
    address internal initializer = makeAddr("initializer");

    function setUp() public {
        dopplerHook = new SwapRestrictorDopplerHook(initializer);
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_StoresAmountsLeft(
        bool isTokenZero,
        PoolKey calldata poolKey,
        address[] calldata approved,
        uint256 maxAmount
    ) public {
        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        PoolId poolId = poolKey.toId();

        for (uint256 i; i < approved.length; i++) {
            vm.expectEmit();
            emit UpdatedAmountLeft(poolId, approved[i], maxAmount);
        }

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, abi.encode(approved, maxAmount));

        for (uint256 i; i < approved.length; i++) {
            assertEq(dopplerHook.amountLeftOf(poolId, approved[i]), maxAmount);
        }
    }

    /* ---------------------------------------------------------------------- */
    /*                                onSwap()                                */
    /* ---------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSenderNotInitializer(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onSwap_DecreasesAmountLeftWhenBuyingAsset(bool isTokenZero, PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        address[] memory approved = new address[](1);
        approved[0] = address(0x123);
        uint256 maxAmount = 1e18;

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, abi.encode(approved, maxAmount));

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: !isTokenZero, amountSpecified: 0, sqrtPriceLimitX96: 0 });

        vm.expectEmit();
        emit UpdatedAmountLeft(poolKey.toId(), approved[0], 0);

        vm.prank(initializer);
        dopplerHook.onSwap(
            approved[0],
            poolKey,
            swapParams,
            toBalanceDelta(isTokenZero ? int128(1e18) : int128(0), isTokenZero ? int128(0) : int128(1e18)),
            new bytes(0)
        );

        assertEq(dopplerHook.amountLeftOf(poolKey.toId(), approved[0]), 0);
    }

    function test_onSwap_IgnoresAmountLeftWhenSellingAsset(bool isTokenZero, PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        address[] memory approved = new address[](1);
        approved[0] = address(0x123);
        uint256 maxAmount = 1e18;

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, abi.encode(approved, maxAmount));

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: !isTokenZero, amountSpecified: 0, sqrtPriceLimitX96: 0 });

        vm.prank(initializer);
        dopplerHook.onSwap(
            approved[0],
            poolKey,
            swapParams,
            toBalanceDelta(!isTokenZero ? int128(1e18) : int128(0), !isTokenZero ? int128(0) : int128(1e18)),
            new bytes(0)
        );

        assertEq(dopplerHook.amountLeftOf(poolKey.toId(), approved[0]), maxAmount);
    }

    function test_onSwap_RevertsWhenTryingToBuyMoreThanLeftAmount(bool isTokenZero, PoolKey calldata poolKey) public {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));

        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        address[] memory approved = new address[](1);
        approved[0] = address(0x123);
        uint256 maxAmount = 1e18;

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, abi.encode(approved, maxAmount));

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: !isTokenZero, amountSpecified: 0, sqrtPriceLimitX96: 0 });

        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientAmountLeft.selector,
                poolKey.toId(),
                approved[0],
                2e18,
                dopplerHook.amountLeftOf(poolKey.toId(), approved[0])
            )
        );

        vm.prank(initializer);
        dopplerHook.onSwap(
            approved[0],
            poolKey,
            swapParams,
            toBalanceDelta(isTokenZero ? int128(2e18) : int128(0), isTokenZero ? int128(0) : int128(2e18)),
            new bytes(0)
        );
    }
}
