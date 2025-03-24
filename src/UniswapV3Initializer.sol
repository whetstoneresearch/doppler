// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/// @notice Thrown when the caller is not the Pool contract
error OnlyPool();

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

error CannotMintZeroLiquidity();

/// @notice Thrown when the specified fee is not set in the Uniswap V3 factory
error InvalidFee(uint24 fee);

/// @notice Thrown when the tick range is misordered
error InvalidTickRangeMisordered(int24 tickLower, int24 tickUpper);

/// @notice Thrown when a tick is not aligned with the tick spacing
error InvalidTickRange(int24 tick, int24 tickSpacing);

/// @notice Thrown when the max share to be sold exceeds the maximum unit
error MaxShareToBeSoldExceeded(uint256 value, uint256 limit);

/// @dev Constant used to increase precision during calculations
uint256 constant WAD = 1e18;

struct InitData {
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    uint256 maxShareToBeSold;
}

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

struct PoolState {
    address asset;
    address numeraire;
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    bool isInitialized;
    bool isExited;
    uint256 maxShareToBeSold;
    uint256 totalTokensOnBondingCurve;
}

struct LpPosition {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint16 id;
}

contract UniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @notice Address of the Uniswap V3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Returns the state of a pool
    mapping(address pool => PoolState state) public getState;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param factory_ Address of the Uniswap V3 factory
     */
    constructor(address airlock_, IUniswapV3Factory factory_) ImmutableAirlock(airlock_) {
        factory = factory_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external onlyAirlock returns (address pool) {
        InitData memory initData = abi.decode(data, (InitData));
        (uint24 fee, int24 tickLower, int24 tickUpper, uint16 numPositions, uint256 maxShareToBeSold) =
            (initData.fee, initData.tickLower, initData.tickUpper, initData.numPositions, initData.maxShareToBeSold);

        require(maxShareToBeSold <= WAD, MaxShareToBeSoldExceeded(maxShareToBeSold, WAD));
        require(tickLower < tickUpper, InvalidTickRangeMisordered(tickLower, tickUpper));

        int24 tickSpacing = factory.feeAmountTickSpacing(fee);
        if (tickSpacing == 0) revert InvalidFee(fee);

        checkPoolParams(tickLower, tickSpacing);
        checkPoolParams(tickUpper, tickSpacing);

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        uint256 numTokensToSell = FullMath.mulDiv(totalTokensOnBondingCurve, maxShareToBeSold, WAD);
        uint256 numTokensToBond = totalTokensOnBondingCurve - numTokensToSell;

        pool = factory.getPool(token0, token1, fee);
        require(getState[pool].isInitialized == false, PoolAlreadyInitialized());

        bool isToken0 = asset == token0;

        if (pool == address(0)) {
            pool = factory.createPool(token0, token1, fee);
        }
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? tickLower : tickUpper);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }

        getState[pool] = PoolState({
            asset: asset,
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            isInitialized: true,
            isExited: false,
            numPositions: numPositions,
            maxShareToBeSold: maxShareToBeSold,
            totalTokensOnBondingCurve: totalTokensOnBondingCurve
        });

        (LpPosition[] memory lbpPositions, uint256 reserves) =
            calculateLogNormalDistribution(tickLower, tickUpper, tickSpacing, isToken0, numPositions, numTokensToSell);

        lbpPositions[numPositions] =
            calculateLpTail(numPositions, tickLower, tickUpper, isToken0, reserves, numTokensToBond, tickSpacing);

        mintPositions(asset, numeraire, fee, pool, lbpPositions, numPositions);

        emit Create(pool, asset, numeraire);
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address pool
    )
        external
        onlyAirlock
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        require(getState[pool].isExited == false, PoolAlreadyExited());
        getState[pool].isExited = true;

        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tick;
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();

        address asset = getState[pool].asset;

        bool isToken0 = asset == token0;

        int24 farTick = isToken0 ? getState[pool].tickUpper : getState[pool].tickLower;
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));

        uint16 numPositions = getState[pool].numPositions;

        uint256 numTokensToSell =
            FullMath.mulDiv(getState[pool].totalTokensOnBondingCurve, getState[pool].maxShareToBeSold, WAD);
        uint256 numTokensToBond = getState[pool].totalTokensOnBondingCurve - numTokensToSell;

        (LpPosition[] memory lbpPositions, uint256 reserves) = calculateLogNormalDistribution(
            getState[pool].tickLower, getState[pool].tickUpper, tickSpacing, isToken0, numPositions, numTokensToSell
        );

        lbpPositions[numPositions] = calculateLpTail(
            numPositions,
            getState[pool].tickLower,
            getState[pool].tickUpper,
            isToken0,
            reserves,
            numTokensToBond,
            tickSpacing
        );

        uint256 amount0;
        uint256 amount1;
        (amount0, amount1, balance0, balance1) = burnPositionsMultiple(pool, lbpPositions, numPositions);

        fees0 = uint128(balance0 - amount0);
        fees1 = uint128(balance1 - amount1);

        ERC20(token0).safeTransfer(msg.sender, balance0);
        ERC20(token1).safeTransfer(msg.sender, balance1);
    }

    /// @inheritdoc IPoolInitializer
    // todo: make this actually exist in the poolinitializer
    function collectAndPushFees(
        address pool
    ) external onlyAirlock returns (uint256 fees0, uint256 fees1) {
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        uint16 numPositions = getState[pool].numPositions;
        bool isToken0 = getState[pool].asset == token0;

        uint256 numTokensToSell =
            FullMath.mulDiv(getState[pool].totalTokensOnBondingCurve, getState[pool].maxShareToBeSold, WAD);
        uint256 numTokensToBond = getState[pool].totalTokensOnBondingCurve - numTokensToSell;

        (LpPosition[] memory lbpPositions, uint256 reserves) = calculateLogNormalDistribution(
            getState[pool].tickLower, getState[pool].tickUpper, tickSpacing, isToken0, numPositions, numTokensToSell
        );

        lbpPositions[numPositions] = calculateLpTail(
            numPositions,
            getState[pool].tickLower,
            getState[pool].tickUpper,
            isToken0,
            reserves,
            numTokensToBond,
            tickSpacing
        );

        (fees0, fees1) = collectPositionsMultiple(pool, lbpPositions, numPositions);

        if (fees0 != 0) {
            ERC20(token0).safeTransfer(address(airlock), fees0);
        }

        if (fees1 != 0) {
            ERC20(token1).safeTransfer(address(airlock), fees1);
        }
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);

        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).safeTransferFrom(address(airlock), pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }

    function alignTickToTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }

    /// @notice Calculates the final LP position that extends from the far tick to the pool's min/max tick
    /// @dev This position ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
    function calculateLpTail(
        uint16 id,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0,
        uint256 reserves,
        uint256 bondingAssetsRemaining,
        int24 tickSpacing
    ) internal pure returns (LpPosition memory lpTail) {
        int24 tailTick = isToken0 ? tickUpper : tickLower;

        uint160 sqrtPriceAtTail = TickMath.getSqrtPriceAtTick(tailTick);

        uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceAtTail,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            isToken0 ? bondingAssetsRemaining : reserves,
            isToken0 ? reserves : bondingAssetsRemaining
        );

        int24 posTickLower = isToken0 ? tailTick : alignTickToTickSpacing(isToken0, TickMath.MIN_TICK, tickSpacing);
        int24 posTickUpper = isToken0 ? alignTickToTickSpacing(isToken0, TickMath.MAX_TICK, tickSpacing) : tailTick;

        require(posTickLower < posTickUpper, InvalidTickRangeMisordered(posTickLower, posTickUpper));

        lpTail = LpPosition({ tickLower: posTickLower, tickUpper: posTickUpper, liquidity: lpTailLiquidity, id: id });
    }

    /// @notice Calculates the distribution of liquidity positions across tick ranges
    /// @dev For example, with 1000 tokens and 10 bins starting at tick 0:
    ///      - Creates positions: [0,10], [1,10], [2,10], ..., [9,10]
    ///      - Each position gets an equal share of tokens (100 tokens each)
    ///      This creates a linear distribution of liquidity across the tick range
    function calculateLogNormalDistribution(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        bool isToken0,
        uint16 totalPositions,
        uint256 totalAmtToBeSold
    ) internal pure returns (LpPosition[] memory, uint256) {
        int24 farTick = isToken0 ? tickUpper : tickLower;
        int24 closeTick = isToken0 ? tickLower : tickUpper;

        int24 spread = tickUpper - tickLower;

        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
        uint256 amountPerPosition = FullMath.mulDiv(totalAmtToBeSold, WAD, totalPositions * WAD);
        uint256 totalAssetsSold;
        LpPosition[] memory newPositions = new LpPosition[](totalPositions + 1);
        uint256 reserves;

        for (uint256 i; i < totalPositions; i++) {
            // calculate the ticks position * 1/n to optimize the division
            int24 startingTick = isToken0
                ? closeTick + int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), totalPositions)))
                : closeTick - int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), totalPositions)));

            // round the tick to the nearest bin
            startingTick = alignTickToTickSpacing(isToken0, startingTick, tickSpacing);

            if (startingTick != farTick) {
                uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingTick);

                // if totalAmtToBeSold is 0, we skip the liquidity calculation as we are burning max liquidity
                // in each position
                uint128 liquidity;
                if (totalAmtToBeSold != 0) {
                    liquidity = isToken0
                        ? LiquidityAmounts.getLiquidityForAmount0(startingSqrtPriceX96, farSqrtPriceX96, amountPerPosition)
                        : LiquidityAmounts.getLiquidityForAmount1(farSqrtPriceX96, startingSqrtPriceX96, amountPerPosition);

                    totalAssetsSold += (
                        isToken0
                            ? SqrtPriceMath.getAmount0Delta(startingSqrtPriceX96, farSqrtPriceX96, liquidity, true)
                            : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, startingSqrtPriceX96, liquidity, true)
                    );

                    // note: we keep track how the theoretical reserves amount at that time to then calculate the breakeven liquidity amount
                    // once we get to the end of the loop, we will know exactly how many of the reserve assets have been raised, and we can
                    // calculate the total amount of reserves after the endTick which makes swappers and LPs indifferent between Uniswap v2 (CPMM) and Uniswap v3 (CLAMM)
                    // we can then bond the tokens to the Uniswap v2 pool by moving them over to the Uniswap v3 pool whenever possible, but there is no rush as it goes up
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

                newPositions[i] = LpPosition({
                    tickLower: farSqrtPriceX96 < startingSqrtPriceX96 ? farTick : startingTick,
                    tickUpper: farSqrtPriceX96 < startingSqrtPriceX96 ? startingTick : farTick,
                    liquidity: liquidity,
                    id: uint16(i)
                });
            }
        }

        require(totalAssetsSold <= totalAmtToBeSold, CannotMintZeroLiquidity());

        return (newPositions, reserves);
    }

    function mintPositions(
        address asset,
        address numeraire,
        uint24 fee,
        address pool,
        LpPosition[] memory newPositions,
        uint16 numPositions
    ) internal {
        for (uint256 i; i <= numPositions; i++) {
            IUniswapV3Pool(pool).mint(
                address(this),
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                newPositions[i].liquidity,
                abi.encode(CallbackData({ asset: asset, numeraire: numeraire, fee: fee }))
            );
        }
    }

    function checkPoolParams(int24 tick, int24 tickSpacing) internal pure {
        if (tick % tickSpacing != 0) revert InvalidTickRange(tick, tickSpacing);
    }

    function collectPositionsMultiple(
        address pool,
        LpPosition[] memory newPositions,
        uint16 numPositions
    ) internal returns (uint256 fees0Total, uint256 fees1Total) {
        uint128 posFees0;
        uint128 posFees1;

        for (uint256 i; i <= numPositions; i++) {
            (posFees0, posFees1) = IUniswapV3Pool(pool).collect(
                address(this),
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                type(uint128).max,
                type(uint128).max
            );

            // since the earlier positions must be hit if , we early return for gas savings
            // TODO: check if this is actually needed
            if (posFees0 == 0 && posFees1 == 0) {
                break;
            }

            fees0Total += posFees0;
            fees1Total += posFees1;
        }
    }

    function burnPositionsMultiple(
        address pool,
        LpPosition[] memory newPositions,
        uint16 numPositions
    ) internal returns (uint256 amount0, uint256 amount1, uint128 balance0, uint128 balance1) {
        uint256 posAmount0;
        uint256 posAmount1;
        uint128 posBalance0;
        uint128 posBalance1;
        for (uint256 i; i <= numPositions; i++) {
            (posAmount0, posAmount1) = IUniswapV3Pool(pool).burn(
                newPositions[i].tickLower, newPositions[i].tickUpper, newPositions[i].liquidity
            );
            (posBalance0, posBalance1) = IUniswapV3Pool(pool).collect(
                address(this),
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                type(uint128).max,
                type(uint128).max
            );

            amount0 += posAmount0;
            amount1 += posAmount1;

            balance0 += posBalance0;
            balance1 += posBalance1;
        }
    }
}
