// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Position } from "src/types/Position.sol";
import { calculateLpTail } from "src/libraries/Multicurve.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

contract MulticurveTest is Test {
    function test_calculateLpTail() public view {
        bytes32 salt = bytes32("salt");
        int24 tickLower = 160_000;
        int24 tickUpper = 240_000;
        bool isToken0 = true;
        uint256 bondingAssetsRemaining = 1e18;
        int24 tickSpacing = 8;

        Position memory lpTail =
            calculateLpTail(salt, tickLower, tickUpper, isToken0, bondingAssetsRemaining, tickSpacing);

        assertEq(lpTail.salt, salt, "Incorrect salt");
        assertEq(lpTail.tickLower, tickUpper, "Incorrect lower tick");
        assertEq(lpTail.tickUpper, TickMath.MAX_TICK, "Incorrect upper tick");
        assertGt(lpTail.liquidity, 0, "Incorrect liquidity");
    }
}
