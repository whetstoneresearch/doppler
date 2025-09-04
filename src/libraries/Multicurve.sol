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

/// @notice Thrown when a curve has zero positions
error ZeroPosition();

/// @notice Thrown when a curve has zero share to be sold
error ZeroShare();

/// @notice Thrown when total shares are invalid (greater than WAD)
error InvalidTotalShares();

/**
 * @dev Representation of a curve shape
 * @param tickLower Lower tick of the curve
 * @param tickUpper Upper tick of the curve
 * @param numPositions Number of positions to create for this curve
 * @param share Amount of shares to be sold on this curve (in WAD)
 */
struct Curve {
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    uint256 shares;
}

/**
 * @dev Adjusts and validates curves with an offset, and returns them along with the overall boundaries
 * @param curves Array of curves to adjust and validate
 * @param offset Offset to apply expressed in tick (`0` if no offset needed)
 * @param tickSpacing Current tick spacing of the pool
 * @param isToken0 True if the asset we're selling is token0, false otherwise
 * @return adjustedCurves Array of adjusted and validated curves
 * @return lowerTickBoundary Overall lower tick boundary across all curves
 * @return upperTickBoundary Overall upper tick boundary across all curves
 */
function adjustCurves(
    Curve[] memory curves,
    int24 offset,
    int24 tickSpacing,
    bool isToken0
) pure returns (Curve[] memory adjustedCurves, int24 lowerTickBoundary, int24 upperTickBoundary) {
    uint256 length = curves.length;
    adjustedCurves = new Curve[](length);

    uint256 totalShares;

    lowerTickBoundary = TickMath.MAX_TICK;
    upperTickBoundary = TickMath.MIN_TICK;

    for (uint256 i; i != length; ++i) {
        Curve memory adjustedCurve = Curve({
            tickLower: curves[i].tickLower,
            tickUpper: curves[i].tickUpper,
            numPositions: curves[i].numPositions,
            shares: curves[i].shares
        });

        require(adjustedCurve.numPositions > 0, ZeroPosition());
        require(adjustedCurve.shares > 0, ZeroShare());

        // Flip the ticks if the asset is token1
        if (!isToken0) {
            (adjustedCurve.tickLower, adjustedCurve.tickUpper) = (-adjustedCurve.tickUpper, -adjustedCurve.tickLower);
        }

        if (offset != 0) {
            isTickAligned(offset, tickSpacing);
            adjustedCurve.tickLower += offset;
            adjustedCurve.tickUpper += offset;
        }

        isTickAligned(adjustedCurve.tickLower, tickSpacing);
        isTickAligned(adjustedCurve.tickUpper, tickSpacing);

        isRangeOrdered(adjustedCurve.tickLower, adjustedCurve.tickUpper);

        // Calculate the boundaries
        if (lowerTickBoundary > adjustedCurve.tickLower) lowerTickBoundary = adjustedCurve.tickLower;
        if (upperTickBoundary < adjustedCurve.tickUpper) upperTickBoundary = adjustedCurve.tickUpper;

        // Accumulate the shares
        totalShares += adjustedCurves[i].shares;

        adjustedCurves[i] = adjustedCurve;
    }

    require(totalShares == WAD, InvalidTotalShares());
    // TODO: Might be an unnecessary check
    isRangeOrdered(lowerTickBoundary, upperTickBoundary);
}

/**
 * @dev From an array of curves, calculates the positions to be created along with the final LP tail position
 * @param curves Array of curves to process
 * @param tickSpacing Tick spacing of the Uniswap V4 pool
 * @param numTokensToSell Total amount of asset tokens to provide
 * @param isToken0 True if the asset we're selling is token0, false otherwise
 */
function calculatePositions(
    Curve[] memory curves,
    int24 tickSpacing,
    uint256 numTokensToSell,
    uint256 otherCurrencySupply,
    bool isToken0
) pure returns (Position[] memory positions) {
    uint256 length = curves.length;
    uint256 totalShares;

    int24 lowerTickBoundary = TickMath.MAX_TICK;
    int24 upperTickBoundary = TickMath.MIN_TICK;

    for (uint256 i; i != length; ++i) {
        totalShares += curves[i].shares;

        // Calculate the boundaries
        if (lowerTickBoundary > curves[i].tickLower) lowerTickBoundary = curves[i].tickLower;
        if (upperTickBoundary < curves[i].tickUpper) upperTickBoundary = curves[i].tickUpper;

        // Calculate the positions for this curve
        uint256 curveSupply = FullMath.mulDiv(numTokensToSell, curves[i].shares, WAD);
        Position[] memory newPositions = calculateLogNormalDistribution(
            i, curves[i].tickLower, curves[i].tickUpper, tickSpacing, isToken0, curves[i].numPositions, curveSupply
        );

        positions = concat(positions, newPositions);
    }

    require(totalShares == WAD, InvalidTotalShares());

    // If there's any supply of the other currency, we can compute the head position using the inverse logic of the tail
    if (otherCurrencySupply > 0) {
        Position memory headPosition = calculateLpTail(
            bytes32(positions.length), lowerTickBoundary, upperTickBoundary, !isToken0, otherCurrencySupply, tickSpacing
        );

        if (headPosition.liquidity > 0) {
            positions = concat(positions, new Position[](1));
            positions[positions.length - 1] = headPosition;
        }
    }
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
) pure returns (Position[] memory) {
    int24 farTick = isToken0 ? tickUpper : tickLower;
    int24 closeTick = isToken0 ? tickLower : tickUpper;
    int24 spread = tickUpper - tickLower;

    uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
    uint256 amountPerPosition = curveSupply / numPositions;
    uint256 totalAssetSupplied;
    Position[] memory positions = new Position[](numPositions);

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
                    ? LiquidityAmounts.getLiquidityForAmount0(startingSqrtPriceX96, farSqrtPriceX96, amountPerPosition - 1)
                    : LiquidityAmounts.getLiquidityForAmount1(farSqrtPriceX96, startingSqrtPriceX96, amountPerPosition - 1);

                totalAssetSupplied += (
                    isToken0
                        ? SqrtPriceMath.getAmount0Delta(startingSqrtPriceX96, farSqrtPriceX96, liquidity, true)
                        : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, startingSqrtPriceX96, liquidity, true)
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

    return positions;
}

/**
 * @dev Calculates the final LP position that extends from the far tick to the pool's min/max tick, this position
 * ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
 * @param salt Salt of the position, likely its index in the array of positions
 * @param tickLower Global lower tick of the bonding curve range
 * @param tickUpper Global upper tick of the bonding curve range
 * @param isToken0 True if the asset we're selling is token0, false otherwise
 * @param supply Amount of asset tokens remaining to be bonded in the LP tail position
 * @param tickSpacing Tick spacing of the Uniswap V4 pool
 * @return lpTail Final LP tail position
 */
function calculateLpTail(
    bytes32 salt,
    int24 tickLower,
    int24 tickUpper,
    bool isToken0,
    uint256 supply,
    int24 tickSpacing
) pure returns (Position memory lpTail) {
    int24 tailTick = isToken0 ? tickUpper : tickLower;
    uint160 sqrtPriceAtTail = TickMath.getSqrtPriceAtTick(tailTick);

    int24 posTickLower = isToken0 ? tailTick + tickSpacing : alignTick(isToken0, TickMath.MIN_TICK, tickSpacing);
    int24 posTickUpper = isToken0 ? alignTick(isToken0, TickMath.MAX_TICK, tickSpacing) : tailTick - tickSpacing;

    uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceAtTail,
        TickMath.getSqrtPriceAtTick(posTickLower),
        TickMath.getSqrtPriceAtTick(posTickUpper),
        isToken0 ? supply : 0,
        isToken0 ? 0 : supply
    );

    require(posTickLower < posTickUpper, TickRangeMisordered(posTickLower, posTickUpper));

    lpTail = Position({ tickLower: posTickLower, tickUpper: posTickUpper, liquidity: lpTailLiquidity, salt: salt });
}
