// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";

contract IncentivesTest is OpeningAuctionBaseTest {
    function test_calculateIncentives_ReturnsZeroBeforeSettlement() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        _addBid(alice, tickLower, 1000e18);

        // Before settlement, should return 0
        uint256 incentives = hook.calculateIncentives(1);
        assertEq(incentives, 0);
    }

    function test_calculateIncentives_ReturnsZeroWhenNoAccumulatedTime() public {
        _warpToAuctionEnd();
        hook.settleAuction();

        // No positions exist, so this should return 0
        uint256 incentives = hook.calculateIncentives(1);
        assertEq(incentives, 0);
    }

    function test_claimIncentives_RevertsWhenNotSettled() public {
        int24 tickLower = hook.minAcceptableTick() + key.tickSpacing * 10;
        _addBid(alice, tickLower, 1000e18);

        vm.expectRevert(IOpeningAuction.AuctionNotSettled.selector);
        hook.claimIncentives(1);
    }

    function test_claimIncentives_RevertsWhenPositionNotFound() public {
        _warpToAuctionEnd();
        hook.settleAuction();

        vm.expectRevert(IOpeningAuction.PositionNotFound.selector);
        hook.claimIncentives(999);
    }

    // Note: Tests for claimIncentives with actual positions are moved to integration
    // tests because they require settlement with proper swap setup.

    function test_incentiveTokensTotal_IsCorrectlyCalculated() public {
        // Default is 10% of auction tokens
        uint256 expectedIncentives = (DEFAULT_AUCTION_TOKENS * DEFAULT_INCENTIVE_SHARE_BPS) / 10_000;
        assertEq(hook.incentiveTokensTotal(), expectedIncentives);
    }
}
