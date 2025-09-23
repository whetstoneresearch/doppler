// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";

import { TickMath } from "@v4-core/libraries/TickMath.sol";

import { isTickAligned } from "src/libraries/TickLibrary.sol";
import { Position } from "src/types/Position.sol";
import {
    adjustCurves,
    calculateLpTail,
    calculateLogNormalDistribution,
    calculatePositions,
    Curve,
    InvalidTotalShares,
    ZeroPosition,
    ZeroShare
} from "src/libraries/Multicurve.sol";
import { WAD } from "src/types/Wad.sol";

contract MulticurveTest is Test {
    /* ---------------------------------------------------------------------------- */
    /*                                adjustCurves()                                */
    /* ---------------------------------------------------------------------------- */

    function test_adjustCurves_ReturnsSameAmountOfCurves() public pure {
        Curve[] memory curves = new Curve[](4);

        curves[0].tickLower = 160_000;
        curves[0].tickUpper = 480_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD / 4;

        curves[1].tickLower = 240_000;
        curves[1].tickUpper = 480_000;
        curves[1].numPositions = 1;
        curves[1].shares = WAD / 4;

        curves[2].tickLower = 320_000;
        curves[2].tickUpper = 480_000;
        curves[2].numPositions = 1;
        curves[2].shares = WAD / 4;

        curves[3].tickLower = 400_000;
        curves[3].tickUpper = 480_000;
        curves[3].numPositions = 1;
        curves[3].shares = WAD / 4;

        (Curve[] memory adjustedCurves,,) = adjustCurves(curves, 0, int24(8), true);
        assertEq(adjustedCurves.length, curves.length, "Incorrect number of curves");
    }

    function test_adjustCurves_NoOffset() public pure {
        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 160_000;
        curves[0].tickUpper = 240_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD;

        (Curve[] memory adjustedCurves, int24 lowerTickBounday, int24 upperTickBoundary) =
            adjustCurves(curves, 0, int24(8), true);

        assertEq(adjustedCurves.length, 1, "Incorrect number of curves");
        assertEq(adjustedCurves[0].tickLower, curves[0].tickLower, "Incorrect lower tick");
        assertEq(adjustedCurves[0].tickUpper, curves[0].tickUpper, "Incorrect upper tick");
        assertEq(adjustedCurves[0].numPositions, 1, "Incorrect number of positions");
        assertEq(adjustedCurves[0].shares, WAD, "Incorrect shares");
        assertEq(lowerTickBounday, 160_000, "Incorrect lower tick boundary");
        assertEq(upperTickBoundary, 240_000, "Incorrect upper tick boundary");
    }

    function test_adjustCurves_NoOffsetNotTokenZero() public pure {
        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 160_000;
        curves[0].tickUpper = 240_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD;

        (Curve[] memory adjustedCurves, int24 lowerTickBounday, int24 upperTickBoundary) =
            adjustCurves(curves, 0, int24(8), false);

        assertEq(adjustedCurves.length, 1, "Incorrect number of curves");
        assertEq(adjustedCurves[0].tickLower, -curves[0].tickUpper, "Incorrect lower tick");
        assertEq(adjustedCurves[0].tickUpper, -curves[0].tickLower, "Incorrect upper tick");
        assertEq(adjustedCurves[0].numPositions, 1, "Incorrect number of positions");
        assertEq(adjustedCurves[0].shares, WAD, "Incorrect shares");
        assertEq(lowerTickBounday, -240_000, "Incorrect lower tick boundary");
        assertEq(upperTickBoundary, -160_000, "Incorrect upper tick boundary");
    }

    function test_adjustCurves_WithOffset() public pure {
        int24 offset = 16_000;

        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 0;
        curves[0].tickUpper = 32_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD;

        (Curve[] memory adjustedCurves, int24 lowerTickBounday, int24 upperTickBoundary) =
            adjustCurves(curves, offset, int24(8), true);

        assertEq(adjustedCurves.length, 1, "Incorrect number of curves");
        assertEq(adjustedCurves[0].tickLower, curves[0].tickLower + offset, "Incorrect lower tick");
        assertEq(adjustedCurves[0].tickUpper, curves[0].tickUpper + offset, "Incorrect upper tick");
        assertEq(adjustedCurves[0].numPositions, 1, "Incorrect number of positions");
        assertEq(adjustedCurves[0].shares, WAD, "Incorrect shares");
        assertEq(lowerTickBounday, curves[0].tickLower + offset, "Incorrect lower tick boundary");
        assertEq(upperTickBoundary, curves[0].tickUpper + offset, "Incorrect upper tick boundary");
    }

    function test_adjustCurves_WithOffsetNotTokenZero() public pure {
        int24 offset = 16_000;

        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 0;
        curves[0].tickUpper = 32_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD;

        (Curve[] memory adjustedCurves, int24 lowerTickBounday, int24 upperTickBoundary) =
            adjustCurves(curves, offset, int24(8), false);

        assertEq(adjustedCurves.length, 1, "Incorrect number of curves");
        assertEq(adjustedCurves[0].tickLower, -curves[0].tickUpper + offset, "Incorrect lower tick");
        assertEq(adjustedCurves[0].tickUpper, -curves[0].tickLower + offset, "Incorrect upper tick");
        assertEq(adjustedCurves[0].numPositions, 1, "Incorrect number of positions");
        assertEq(adjustedCurves[0].shares, WAD, "Incorrect shares");
        assertEq(lowerTickBounday, -curves[0].tickUpper + offset, "Incorrect lower tick boundary");
        assertEq(upperTickBoundary, -curves[0].tickLower + offset, "Incorrect upper tick boundary");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_adjustCurves_RevertsIfZeroPosition() public {
        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 0;
        curves[0].tickUpper = 32_000;
        curves[0].numPositions = 0;
        curves[0].shares = WAD;

        vm.expectRevert(ZeroPosition.selector);
        adjustCurves(curves, 0, int24(8), false);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_adjustCurves_RevertsIfZeroShare() public {
        Curve[] memory curves = new Curve[](1);
        curves[0].tickLower = 0;
        curves[0].tickUpper = 32_000;
        curves[0].numPositions = 1;
        curves[0].shares = 0;

        vm.expectRevert(ZeroShare.selector);
        adjustCurves(curves, 0, int24(8), false);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_adjustCurves_RevertsIfInvalidTotalShares() public {
        Curve[] memory curves = new Curve[](2);
        curves[0].tickLower = 0;
        curves[0].tickUpper = 32_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD / 2;

        curves[1].tickLower = 32_000;
        curves[1].tickUpper = 64_000;
        curves[1].numPositions = 1;
        curves[1].shares = WAD / 2 + 1;

        vm.expectRevert(InvalidTotalShares.selector);
        adjustCurves(curves, 0, int24(8), false);
    }

    function test_calculateLpTail() public pure {
        bytes32 salt = bytes32("salt");
        int24 tickLower = 160_000;
        int24 tickUpper = 240_000;
        bool isToken0 = true;
        uint256 supply = 1e18;
        int24 tickSpacing = 8;

        Position memory lpTail = calculateLpTail(salt, tickLower, tickUpper, isToken0, supply, tickSpacing);

        assertEq(lpTail.salt, salt, "Incorrect salt");
        assertEq(lpTail.tickLower, tickUpper + tickSpacing, "Incorrect lower tick");
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

        Position[] memory positions =
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

    function test_calculatePositions() public pure {
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

    /// forge-config: default.allow_internal_expect_revert = true
    function test_calculatePositions_RevertsWhenInvalidTotalShares() public {
        int24 tickSpacing = 8;
        Curve[] memory curves = new Curve[](10);

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 5;
            curves[i].shares = WAD / 11;
        }

        vm.expectRevert(InvalidTotalShares.selector);
        calculatePositions(curves, tickSpacing, 1e27, 0, true);
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

        Position memory headPosition = positions[positions.length - 1];
        assertEq(headPosition.tickLower, TickMath.MIN_TICK, "Incorrect head position lower tick");
        assertEq(headPosition.tickUpper, 160_000 - tickSpacing, "Incorrect head position upper tick");
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
