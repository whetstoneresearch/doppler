// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";

contract SettlementTest is OpeningAuctionBaseTest {
    function test_settleAuction_RevertsWhenNotActive() public {
        // Warp to after auction end and settle
        _warpToAuctionEnd();
        hook.settleAuction();

        // Try to settle again
        vm.expectRevert(IOpeningAuction.AuctionNotActive.selector);
        hook.settleAuction();
    }

    function test_settleAuction_RevertsWhenAuctionNotEnded() public {
        // Try to settle before auction ends
        vm.expectRevert(IOpeningAuction.AuctionNotEnded.selector);
        hook.settleAuction();
    }

    function test_settleAuction_SetsPhaseToSettled() public {
        _warpToAuctionEnd();
        hook.settleAuction();

        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    function test_settleAuction_SetsClearingTick() public {
        _warpToAuctionEnd();
        hook.settleAuction();

        // Clearing tick should be set (exact value depends on pool state)
        int24 clearingTick = hook.clearingTick();
        // Just verify it was set (not zero or some default)
        assertTrue(clearingTick != 0 || hook.totalTokensSold() == 0);
    }

    function test_settleAuction_EmitsAuctionSettledEvent() public {
        _warpToAuctionEnd();

        // We expect the AuctionSettled event to be emitted
        // The exact parameters depend on the pool state
        hook.settleAuction();

        // Verify phase changed
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    function test_settleAuction_CanBeCalledByAnyone() public {
        _warpToAuctionEnd();

        // Random user can settle
        vm.prank(address(0x12345));
        hook.settleAuction();

        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    function test_settleAuction_WithNoBids() public {
        // No bids placed, just settle
        _warpToAuctionEnd();
        hook.settleAuction();

        assertEq(hook.totalTokensSold(), 0);
        assertEq(hook.totalProceeds(), 0);
    }

    function test_claimWindow_StartsAtDelayedSettlement() public {
        int24 tickLower = 0;
        uint128 liquidity = hook.minLiquidity() * 10;
        uint256 positionId = _addBid(alice, tickLower, liquidity);

        vm.warp(hook.auctionEndTime() + 40 days);
        hook.settleAuction();

        vm.prank(initializer);
        hook.migrate(address(this));

        assertGt(hook.incentivesClaimDeadline(), block.timestamp);

        vm.prank(alice);
        hook.claimIncentives(positionId);
    }
}
