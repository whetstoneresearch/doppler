// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { isTickAligned } from "src/libraries/TickLibrary.sol";
import { Position } from "src/types/Position.sol";
import {
    calculateLpTail, calculateLogNormalDistribution, calculatePositions, Curve
} from "src/libraries/Multicurve.sol";
import { WAD } from "src/types/Wad.sol";

contract MulticurveTest is Test {
    function test_calculateLpTail() public pure {
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

    function test_calculateLogNormalDistribution() public pure {
        int24 tickLower = 160_000;
        int24 tickUpper = 240_000;
        int24 tickSpacing = 8;
        bool isToken0 = true;
        uint16 numPositions = 10;
        uint256 curveSupply = 1e27;

        (Position[] memory positions,) =
            calculateLogNormalDistribution(0, tickLower, tickUpper, tickSpacing, isToken0, numPositions, curveSupply);

        assertEq(positions.length, numPositions, "Incorrect number of positions");
        assertEq(positions[0].tickLower, tickLower, "Incorrect first position lower tick");
        assertEq(positions[positions.length - 1].tickUpper, tickUpper, "Incorrect last position upper tick");

        for (uint256 i; i < positions.length; ++i) {
            isTickAligned(positions[i].tickLower, tickSpacing);
            isTickAligned(positions[i].tickUpper, tickSpacing);
            assertGt(positions[i].liquidity, 0, "Liquidity is zero");
        }
    }

    function test_calculatePositions_NoTail() public pure {
        int24 tickSpacing = 8;
        Curve[] memory curves = new Curve[](10);

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 5;
            curves[i].shares = WAD / 10;
        }

        Position[] memory positions = calculatePositions(curves, tickSpacing, 1e27, 0, true);
        assertEq(positions.length, 50, "Incorrect number of positions");
    }

    function test_calculatePositions_WithTail() public pure {
        int24 tickSpacing = 8;
        Curve[] memory curves = new Curve[](10);

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 5;
            curves[i].shares = WAD / 11;
        }

        Position[] memory positions = calculatePositions(curves, tickSpacing, 1e27, 0, true);
        assertEq(positions.length, 51, "Incorrect number of positions");
    }

    function test_calculatePositions_WithHead() public pure {
        int24 tickSpacing = 8;
        Curve[] memory curves = new Curve[](10);

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 5;
            curves[i].shares = WAD / 10;
        }

        Position[] memory positions = calculatePositions(curves, tickSpacing, 8e18, 1e22, true);
        assertEq(positions.length, 51, "Incorrect number of positions");
    }

    function test_calculatePositions_WithHeadAndTail() public pure {
        int24 tickSpacing = 8;
        Curve[] memory curves = new Curve[](10);

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 5;
            curves[i].shares = WAD / 11;
        }

        Position[] memory positions = calculatePositions(curves, tickSpacing, 8e18, 1e22, true);
        assertEq(positions.length, 52, "Incorrect number of positions");
    }

    function _printPositions(
        Position[] memory positions
    ) internal pure {
        for (uint256 i; i < positions.length; ++i) {
            console.log("Position #%s", i);
            console.log("Salt: %s", uint256(positions[i].salt));
            console.log("Lower tick %s", positions[i].tickLower);
            console.log("Upper tick %s", positions[i].tickUpper);
            console.log("Liquidity %s", positions[i].liquidity);
            console.log("-----");
        }
    }
}
