/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest} from "test/BaseTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";

contract SwapTest is BaseTest {
    function test_swap_CanBuyAssetTokens() public {
        address alice = address(0x1);
        vm.startPrank(alice);

        if (ghost().hook.getIsToken0()) {
            ghost().token1.mint(alice, 10_000 ether);
            ghost().token1.approve(address(manager), 10_000 ether);
        } else {
            ghost().token0.mint(alice, 10_000 ether);
            ghost().token1.approve(address(manager), 10_000 ether);
        }

        swapRouter.swap(
            ghost().key(),
            IPoolManager.SwapParams({
                zeroForOne: !ghost().hook.getIsToken0(),
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: !ghost().hook.getIsToken0() ? Deployers.MIN_PRICE_LIMIT : Deployers.MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}