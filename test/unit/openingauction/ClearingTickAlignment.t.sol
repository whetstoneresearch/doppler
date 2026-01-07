// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { QuoterMath } from "src/libraries/QuoterMath.sol";

contract ClearingTickAlignmentTest is OpeningAuctionBaseTest {
    function test_estimatedClearingTick_isFlooredToSpacing() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        _addBid(alice, tickLower, hook.minLiquidity() * 10);

        uint256 tokensToSell = hook.totalAuctionTokens() - hook.incentiveTokensTotal();
        uint160 sqrtPriceLimitX96 = _sqrtPriceLimitX96(hook.minAcceptableTick());

        (,, uint160 sqrtPriceAfterX96,) = QuoterMath.quote(
            manager,
            key,
            IPoolManager.SwapParams({
                zeroForOne: hook.isToken0(),
                amountSpecified: -int256(tokensToSell),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        int24 quotedTick = TickMath.getTickAtSqrtPrice(sqrtPriceAfterX96);
        int24 expected = _floorToSpacing(quotedTick, key.tickSpacing);

        assertEq(hook.estimatedClearingTick(), expected);
    }

    function _sqrtPriceLimitX96(int24 limitTick) internal pure returns (uint160) {
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        if (limit <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (limit >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
        return limit;
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed * spacing;
    }
}
