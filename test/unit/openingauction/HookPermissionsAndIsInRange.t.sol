// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import { OpeningAuctionBaseTest } from "test/shared/OpeningAuctionBaseTest.sol";

/// @notice Regression tests for production hook-address validation and isInRange semantics.
contract HookPermissionsAndIsInRangeTest is OpeningAuctionBaseTest {
    /// @dev In production, BaseHook's constructor calls Hooks.validateHookPermissions.
    ///      Our unit tests often bypass that to allow deployCodeTo() at a mined address.
    ///      This test ensures the mined address flags still match getHookPermissions().
    function test_hookPermissions_MatchMinedAddressFlags() public {
        // Should not revert.
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
    }

    /// @notice After settlement, isInRange should mean "touched by settlement swap",
    ///         not "final tick is inside the position".
    function test_isInRange_PostSettlement_UsesTouchedSemantics() public {
        // Use tiny liquidity so the settlement swap crosses the 0 tick.
        uint128 liq = DEFAULT_MIN_LIQUIDITY;

        int24 tickAt0 = 0;
        int24 tickBelow0 = -key.tickSpacing;

        uint256 posAt0 = _addBid(alice, tickAt0, liq);
        _addBid(bob, tickBelow0, liq);

        _warpToAuctionEnd();
        hook.settleAuction();

        int24 clearTick = hook.clearingTick();

        // We expect to have crossed below tick 0 with the tiny liquidity.
        assertLt(clearTick, tickAt0, "clearing tick should be below 0");

        // Final tick is NOT inside [0, tickSpacing).
        bool finalTickInside = (clearTick >= tickAt0) && (clearTick < tickAt0 + key.tickSpacing);
        assertFalse(finalTickInside, "final tick unexpectedly inside [0, tickSpacing)");

        // But the position should still be considered "in range" (touched by settlement).
        assertTrue(hook.isInRange(posAt0), "position at 0 should be marked as touched");
    }
}
