// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { AuctionPhase } from "src/interfaces/IOpeningAuction.sol";

contract OpeningAuctionMaxTickSpamTest is OpeningAuctionBaseTest {
    function test_settleAuction_succeeds_withManyDistinctTicks(uint16 nTicks) public {
        nTicks = uint16(bound(nTicks, 1, 128));

        uint128 liquidity = hook.minLiquidity();
        int24 baseTick = hook.minAcceptableTick();

        for (uint16 i = 0; i < nTicks; i++) {
            int24 tickLower = baseTick + int24(int256(uint256(i)) * int256(key.tickSpacing));
            _addBid(alice, tickLower, liquidity);
        }

        _warpToAuctionEnd();
        hook.settleAuction();

        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }
}
