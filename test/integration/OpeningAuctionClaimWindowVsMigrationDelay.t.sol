// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";

contract OpeningAuctionClaimWindowVsMigrationDelayTest is OpeningAuctionBaseTest {
    function test_claimBeforeMigration_thenMigrate_reservesOnlyUnclaimedIncentives() public {
        TestERC20(asset).transfer(address(hook), 50 ether);

        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        uint256 alicePos = _addBid(alice, tickLower, hook.minLiquidity() * 100);
        _addBid(bob, tickLower, hook.minLiquidity() * 100);

        _warpToAuctionEnd();
        hook.settleAuction();

        vm.warp(hook.incentivesClaimDeadline() - 1);

        vm.prank(alice);
        hook.claimIncentives(alicePos);

        uint256 raw = TestERC20(asset).balanceOf(address(hook));
        uint256 remaining = hook.incentiveTokensTotal() - hook.totalIncentivesClaimed();
        uint256 expected = raw > remaining ? raw - remaining : 0;

        uint256 before = TestERC20(asset).balanceOf(address(this));
        vm.prank(initializer);
        hook.migrate(address(this));
        uint256 afterBal = TestERC20(asset).balanceOf(address(this));

        assertEq(afterBal - before, expected);
    }
}
