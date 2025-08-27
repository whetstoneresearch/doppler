// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { isTickAligned } from "src/libraries/TickLibrary.sol";
import { Position } from "src/types/Position.sol";
import { calculateLpTail, calculateLogNormalDistribution, calculatePositions } from "src/libraries/Multicurve.sol";
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

    function test_calculatePositions() public view {
        int24 tickSpacing = 8;
        int24[] memory tickLower = new int24[](10);
        int24[] memory tickUpper = new int24[](10);
        uint16[] memory numPositions = new uint16[](10);
        uint256[] memory shareToBeSold = new uint256[](10);

        for (uint256 i; i < 10; ++i) {
            tickLower[i] = int24(uint24(160_000 + i * 8));
            tickUpper[i] = 240_000;
            numPositions[i] = 2;
            shareToBeSold[i] = WAD / 10;
        }

        Position[] memory positions = calculatePositions(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(0))
            }),
            true,
            numPositions,
            tickLower,
            tickUpper,
            shareToBeSold,
            1e27
        );

        _printPositions(positions);
    }

    function _printPositions(
        Position[] memory positions
    ) internal view {
        for (uint256 i; i < positions.length; ++i) {
            console.log("-----");
            console.log("Position #%s", i);
            console.log("Salt: %s", uint256(positions[i].salt));
            console.log("Lower tick %s", positions[i].tickLower);
            console.log("Upper tick %s", positions[i].tickUpper);
            console.log("Liquidity %s", positions[i].liquidity);
            console.log("-----");
        }
    }
}
