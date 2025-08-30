// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";

import { Position, concat } from "src/types/Position.sol";
import { isTickAligned, alignTick, TickRangeMisordered, isRangeOrdered } from "src/libraries/TickLibrary.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when a mismatched info length for curves
error InvalidArrayLength();

error ZeroPosition(uint256 index);

error ZeroMaxShare(uint256 index);

/// @notice Thrown when the max share to be sold exceeds the maximum unit
error MaxShareToBeSoldExceeded(uint256 value, uint256 limit);

struct Curve {
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    uint256 share;
}

/// @dev Takes in an array of generic curve parameters (shapes) and applies an offset to them
function adjustCurves(
    bool isToken0,
    int24 tickSpacing,
    int24 offset,
    Curve[] memory curves
) pure returns (Curve[] memory adjustedCurves) {
    adjustedCurves = new Curve[](curves.length);

    uint256 totalShares;
    // int24 lowerTickBoundary;
    // int24 upperTickBoundary;

    uint256 numCurves = curves.length;

    for (uint256 i; i != numCurves; ++i) {
        adjustedCurves[i] = adjustCurve(curves[i], tickSpacing, offset, isToken0);
        totalShares += curves[i].share;
    }

    require(totalShares <= WAD, MaxShareToBeSoldExceeded(totalShares, WAD));
    // isRangeOrdered(lowerTickBoundary, upperTickBoundary);
}

function adjustCurve(
    Curve memory curve,
    int24 tickSpacing,
    int24 offset,
    bool isToken0
) pure returns (Curve memory adjustedCurve) {
    adjustedCurve = curve;

    require(adjustedCurve.numPositions > 0, "ZeroPosition");
    require(adjustedCurve.share > 0, "ZeroMaxShare");

    if (offset != 0) {
        adjustedCurve.tickLower += offset;
        adjustedCurve.tickUpper += offset;
    }

    isTickAligned(adjustedCurve.tickLower, tickSpacing);
    isTickAligned(adjustedCurve.tickUpper, tickSpacing);

    // Flip the ticks if the asset is token1
    if (!isToken0) {
        adjustedCurve.tickLower = -adjustedCurve.tickUpper;
        adjustedCurve.tickUpper = -adjustedCurve.tickLower;
    }

    isRangeOrdered(adjustedCurve.tickLower, adjustedCurve.tickUpper);

    /*
    // Calculate the boundaries
    if (lowerTickBoundary > currentTickLower) lowerTickBoundary = currentTickLower;
    if (upperTickBoundary < currentTickUpper) upperTickBoundary = currentTickUpper;

    adjustedCurves[i] = adjustedCurve;    
    */
}

function validateCurves(
    address asset,
    address numeraire,
    int24 tickSpacing,
    int24[] memory tickLower,
    int24[] memory tickUpper,
    uint16[] memory numPositions,
    uint256[] memory shareToBeSold
) pure returns (int24 startTick) {
    uint256 numCurves = tickLower.length;

    if (
        numCurves != tickUpper.length || numCurves != shareToBeSold.length || numCurves != numPositions.length
            || shareToBeSold.length != numPositions.length
    ) {
        revert InvalidArrayLength();
    }

    // todo determine if we just put the rest on the curve
    uint256 totalShareToBeSold;

    address token0 = asset < numeraire ? asset : numeraire;
    bool isToken0 = token0 == asset;

    int24 lowerTickBoundary = TickMath.MIN_TICK;
    int24 upperTickBoundary = TickMath.MAX_TICK;

    // Check the curves to see if they are safe
    for (uint256 i; i != numCurves; ++i) {
        require(numPositions[i] > 0, ZeroPosition(i));
        require(shareToBeSold[i] > 0, ZeroMaxShare(i));

        totalShareToBeSold += shareToBeSold[i];

        int24 currentTickLower = tickLower[i];
        int24 currentTickUpper = tickUpper[i];

        isTickAligned(currentTickLower, tickSpacing);
        isTickAligned(currentTickUpper, tickSpacing);
        isRangeOrdered(currentTickLower, currentTickUpper);

        // Flip the ticks if the asset is token1
        if (!isToken0) {
            tickLower[i] = -currentTickUpper;
            tickUpper[i] = -currentTickLower;
        }

        // Calculate the boundaries
        if (lowerTickBoundary > currentTickLower) lowerTickBoundary = currentTickLower;
        if (upperTickBoundary < currentTickUpper) upperTickBoundary = currentTickUpper;
    }

    require(totalShareToBeSold <= WAD, MaxShareToBeSoldExceeded(totalShareToBeSold, WAD));
    isRangeOrdered(lowerTickBoundary, upperTickBoundary);

    return isToken0 ? lowerTickBoundary : upperTickBoundary;
}

function calculatePositions(
    PoolKey memory poolKey,
    bool isToken0,
    uint16[] memory numPositions,
    int24[] memory tickLower,
    int24[] memory tickUpper,
    uint256[] memory shareToBeSold,
    uint256 numTokensToSell
) pure returns (Position[] memory positions) {
    uint256 length = tickLower.length;
    uint256 totalAssetSupplied;
    uint256 totalShares;

    for (uint256 i; i != length; ++i) {
        totalShares += shareToBeSold[i];
        uint256 curveSupply = FullMath.mulDiv(numTokensToSell, shareToBeSold[i], WAD);

        // Calculate the positions for this curve
        (Position[] memory newPositions,) = calculateLogNormalDistribution(
            i, tickLower[i], tickUpper[i], poolKey.tickSpacing, isToken0, numPositions[i], curveSupply
        );

        positions = concat(positions, newPositions);

        // Update the bonding assets remaining
        totalAssetSupplied += curveSupply;
    }

    require(totalShares == WAD, "Shares must sum to 1e18");

    // Flush the rest into the tail
    Position memory lpTailPosition = calculateLpTail(
        bytes32(positions.length),
        tickLower[0],
        tickUpper[length - 1],
        isToken0,
        numTokensToSell - totalAssetSupplied,
        poolKey.tickSpacing
    );

    if (lpTailPosition.liquidity > 0) {
        positions = concat(positions, new Position[](1));
        positions[positions.length - 1] = lpTailPosition;
    }
}

/// @notice Calculates the final LP position that extends from the far tick to the pool's min/max tick
/// @dev This position ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
function calculateLpTail(
    bytes32 salt,
    int24 tickLower,
    int24 tickUpper,
    bool isToken0,
    uint256 bondingAssetsRemaining,
    int24 tickSpacing
) pure returns (Position memory lpTail) {
    int24 tailTick = isToken0 ? tickUpper : tickLower;
    uint160 sqrtPriceAtTail = TickMath.getSqrtPriceAtTick(tailTick);

    int24 posTickLower = isToken0 ? tailTick : alignTick(isToken0, TickMath.MIN_TICK, tickSpacing);
    int24 posTickUpper = isToken0 ? alignTick(isToken0, TickMath.MAX_TICK, tickSpacing) : tailTick;

    uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceAtTail,
        TickMath.getSqrtPriceAtTick(posTickLower),
        TickMath.getSqrtPriceAtTick(posTickUpper),
        isToken0 ? bondingAssetsRemaining : 0,
        isToken0 ? 0 : bondingAssetsRemaining
    );

    require(posTickLower < posTickUpper, TickRangeMisordered(posTickLower, posTickUpper));

    lpTail = Position({ tickLower: posTickLower, tickUpper: posTickUpper, liquidity: lpTailLiquidity, salt: salt });
}

/**
 * @notice Calculates the distribution of liquidity positions across tick ranges
 * @dev For example, with 1000 tokens and 10 bins starting at tick 0:
 * - Creates positions: [0,10], [1,10], [2,10], ..., [9,10]
 * - Each position gets an equal share of tokens (100 tokens each)
 * - This creates a linear distribution of liquidity across the tick range
 * @param tickLower Lower tick of the range
 * @param tickUpper Upper tick of the range
 * @param tickSpacing Tick spacing of the pool
 * @param isToken0 True if the asset token is token0, false otherwise
 * @param numPositions Amount of positions to create within the range
 * @param curveSupply Amount of tokens to distribute across the positions
 * @return Array of Position structs
 */
function calculateLogNormalDistribution(
    uint256 index,
    int24 tickLower,
    int24 tickUpper,
    int24 tickSpacing,
    bool isToken0,
    uint16 numPositions,
    uint256 curveSupply
) pure returns (Position[] memory, uint256) {
    int24 farTick = isToken0 ? tickUpper : tickLower;
    int24 closeTick = isToken0 ? tickLower : tickUpper;
    int24 spread = tickUpper - tickLower;

    uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
    uint256 amountPerPosition = FullMath.mulDiv(curveSupply, WAD, numPositions * WAD);
    uint256 totalAssetSupplied;
    Position[] memory positions = new Position[](numPositions);
    uint256 reserves;

    for (uint256 i; i < numPositions; i++) {
        // Calculate the ticks position * 1/n to optimize the division
        int24 startingTick = isToken0
            ? closeTick + int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), numPositions)))
            : closeTick - int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), numPositions)));

        // Round the tick to the nearest bin
        startingTick = alignTick(isToken0, startingTick, tickSpacing);

        if (startingTick != farTick) {
            uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingTick);

            uint128 liquidity;

            // If curveSupply is 0, we skip the liquidity calculation as we are burning max liquidity in each position
            if (curveSupply != 0) {
                liquidity = isToken0
                    ? LiquidityAmounts.getLiquidityForAmount0(startingSqrtPriceX96, farSqrtPriceX96, amountPerPosition)
                    : LiquidityAmounts.getLiquidityForAmount1(farSqrtPriceX96, startingSqrtPriceX96, amountPerPosition);

                totalAssetSupplied += (
                    isToken0
                        ? SqrtPriceMath.getAmount0Delta(startingSqrtPriceX96, farSqrtPriceX96, liquidity, true)
                        : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, startingSqrtPriceX96, liquidity, true)
                );

                // Note: we keep track how the theoretical reserves amount at that time to then calculate the breakeven
                // liquidity amount once we get to the end of the loop, we will know exactly how many of the reserve
                // assets have been raised, and we can calculate the total amount of reserves after the endTick which
                // makes swappers and LPs indifferent between Uniswap v2 (CPMM) and Uniswap v3 (CLAMM) we can then bond
                // the tokens to the Uniswap v2 pool by moving them over to the Uniswap v3 pool whenever possible, but
                // there is no rush as it goes up
                reserves += (
                    isToken0
                        ? SqrtPriceMath.getAmount1Delta(
                            farSqrtPriceX96,
                            startingSqrtPriceX96,
                            liquidity,
                            false // round against the reserves to undercount eventual liquidity
                        )
                        : SqrtPriceMath.getAmount0Delta(
                            startingSqrtPriceX96,
                            farSqrtPriceX96,
                            liquidity,
                            false // round against the reserves to undercount eventual liquidity
                        )
                );
            }

            positions[i] = Position({
                tickLower: farSqrtPriceX96 < startingSqrtPriceX96 ? farTick : startingTick,
                tickUpper: farSqrtPriceX96 < startingSqrtPriceX96 ? startingTick : farTick,
                liquidity: liquidity,
                salt: bytes32(index * numPositions + i)
            });
        }
    }

    require(totalAssetSupplied == curveSupply, "Supply not full used");

    return (positions, reserves);
}
