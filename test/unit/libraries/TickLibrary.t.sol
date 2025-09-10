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
}
