// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";

contract OpeningAuctionSafeCastTest is OpeningAuctionBaseTest {
    function test_addLiquidity_RevertsOnUint128Overflow() public {
        int24 tickLower = hook.minAcceptableTick();
        uint256 tooLarge = uint256(type(uint128).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(SafeCastLib.Overflow.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: int256(tooLarge),
                salt: bytes32("overflow")
            }),
            abi.encode(alice)
        );
    }
}
