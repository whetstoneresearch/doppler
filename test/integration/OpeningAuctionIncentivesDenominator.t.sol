// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";

contract OpeningAuctionIncentivesDenominatorTest is OpeningAuctionBaseTest {
    function test_incentives_sameTick_lateJoin_split() public {
        int24 tickLower = hook.minAcceptableTick();
        uint128 liquidity = hook.minLiquidity() * 10;

        uint256 alicePos = _addBid(alice, tickLower, liquidity);
        vm.warp(block.timestamp + 100);
        uint256 bobPos = _addBid(bob, tickLower, liquidity);

        _warpToAuctionEnd();
        hook.settleAuction();

        vm.prank(initializer);
        hook.migrate(address(this));

        uint256 aliceIncentives = hook.calculateIncentives(alicePos);
        uint256 bobIncentives = hook.calculateIncentives(bobPos);

        assertGt(aliceIncentives, bobIncentives);
        assertApproxEqAbs(aliceIncentives + bobIncentives, hook.incentiveTokensTotal(), 2);
    }
}
