// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";

/// @notice Tests for liquidity removal behavior
/// @dev With the router-based approach, users add/remove liquidity via standard routers.
///      The hook validates and tracks positions, blocking removal of locked positions.
contract WithdrawAndRollTest is OpeningAuctionBaseTest {
    // Note: In the new design, users interact via standard routers.
    // The hook's _beforeRemoveLiquidity callback blocks locked positions.
    // Tests for withdrawBid() and roll() functions have been removed as those
    // functions are no longer part of the hook.

    // Remaining test functionality is covered by:
    // - BeforeAddLiquidity.t.sol for position validation
    // - PositionTracking.t.sol for position tracking via hookData
    // - Integration tests for end-to-end flows
}
