// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

import {
    TickNotAligned,
    TickRangeMisordered,
    alignTick,
    isRangeOrdered,
    isTickAligned,
    isTickSpacingValid
} from "src/libraries/TickLibrary.sol";

contract TickLibraryTest is Test {
    function test_alignTick() public pure {
        assertEq(alignTick(true, -3, 2), int24(-4));
        assertEq(alignTick(true, 3, 2), int24(2));
        assertEq(alignTick(false, -3, 2), int24(-2));
        assertEq(alignTick(false, 3, 2), int24(4));
    }

    function test_isTickAligned(int24 tick, int24 tickSpacing) public pure {
        vm.assume(tickSpacing > 0);
        vm.assume(tick % tickSpacing == 0);
        isTickAligned(tick, tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickAligned_RevertsIfTickNotAligned(int24 tick, int24 tickSpacing) public {
        vm.assume(tickSpacing > 0);
        vm.assume(tick % tickSpacing != 0);
        vm.expectRevert(abi.encodeWithSelector(TickNotAligned.selector, tick));
        isTickAligned(tick, tickSpacing);
    }

    function test_isRangeOrdered(int24 tickLower, int24 tickUpper) public pure {
        vm.assume(tickLower < tickUpper);
        isRangeOrdered(tickLower, tickUpper);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isRangeOrdered_RevertsIfTickRangeMisordered(int24 tickLower, int24 tickUpper) public {
        vm.assume(tickLower > tickUpper);
        vm.expectRevert(abi.encodeWithSelector(TickRangeMisordered.selector, tickLower, tickUpper));
        isRangeOrdered(tickLower, tickUpper);
    }

    function test_isTickSpacingValid(int24 tickSpacing) public pure {
        vm.assume(tickSpacing >= TickMath.MIN_TICK_SPACING);
        vm.assume(tickSpacing <= TickMath.MAX_TICK_SPACING);
        isTickSpacingValid(tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickSpacingValid_RevertsIfTooSmall(int24 tickSpacing) public {
        vm.assume(tickSpacing < 0);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, tickSpacing));
        isTickSpacingValid(tickSpacing);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickSpacingValid_RevertsIfTooLarge(int24 tickSpacing) public {
        vm.assume(tickSpacing > TickMath.MAX_TICK_SPACING);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector, tickSpacing));
        isTickSpacingValid(tickSpacing);
    }
}
