// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import {
    TickNotAligned,
    TickRangeMisordered,
    alignTick,
    isTickAligned,
    isRangeOrdered
} from "src/libraries/TickLibrary.sol";

contract TickLibraryTest is Test {
    function test_alignTick() public pure {
        assertEq(alignTick(true, -3, 2), int24(-4));
        assertEq(alignTick(true, 3, 2), int24(2));
        assertEq(alignTick(false, -3, 2), int24(-2));
        assertEq(alignTick(false, 3, 2), int24(4));
    }

    function test_isTickAligned() public pure {
        isTickAligned(4, 2);
        isTickAligned(-4, 2);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_isTickAligned_RevertsIfTickNotAligned() public {
        vm.expectRevert(abi.encodeWithSelector(TickNotAligned.selector, 3));
        isTickAligned(3, 2);
    }
}
