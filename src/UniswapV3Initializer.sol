/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { TickMath } from "@v3-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "v4-core/test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "@v3-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v3-core/libraries/FullMath.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol"; // do i need this?

error OnlyAirlock();
error OnlyPool();
error PoolAlreadyInitialized();
error PoolAlreadyExited();
error CannotMigrateOutOfRange(int24 expectedTick, int24 currentTick);
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);
error InvalidTargetTick();
error CannotMintZeroLiquidity();

error InvalidFee(uint24 fee);
error InvalidTickRangeMisordered(int24 tickLower, int24 tickUpper);
error InvalidTickRange(int24 tick, int24 tickSpacing);

// is a uint16 too big?
struct InitData {
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
}

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

// todo: check about removing amount
struct PoolState {
    address asset;
    address numeraire;
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    bool isInitialized;
    bool isExited;
}

// extra storage slots
struct lpPosition {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

contract UniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback {
    address public immutable airlock;
    IUniswapV3Factory public immutable factory;

    mapping(address pool => PoolState state) public getState;

    constructor(address airlock_, IUniswapV3Factory factory_) {
        airlock = airlock_;
        factory = factory_;
    }

    // round the tick to a bin
    function binTickOnTickSpacing(int24 tick, int24 tickSpacing) public returns (int24) {
        return (tick / tickSpacing) * tickSpacing;
    }

    // calculates i * spreadBetweenTicks / numPositions, which is growth factor of i/n, i/n+1, i/n+2, ... i/n+n
    function calculateInternalBinPosition(
        uint256 i,
        int24 spreadBetweenTicks,
        uint16 numPositions
    ) public returns (int24 sprBetweenBins) {
        sprBetweenBins = int24(uint24(FullMath.mulDiv(i, uint256(int256(spreadBetweenTicks)), numPositions)));
    }

    // lpTail is the final position in the pool, to give liquidity from the farTick to the end of the pool
    // the LP position is calculated to be the breakeven position between Uniswap v2 and Uniswap v3 between
    // the far tick and the min/max tick of the pool. this means that anyone above the LBP will still have the
    // same execution price as the migrated Uniswap v2 pool in the Uniswap v3.
    // TODO can we check this lol
    function calculatelpTail(
        uint256 bondingAssetsRemaining,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0,
        uint256 reserves,
        int24 tickSpacing
    ) public returns (lpPosition memory lpTail) {
        // should always be equal to the "farTick" in the previous function calculateLogNormalDistribution
        int24 tailTick = isToken0 ? tickUpper : tickLower;

        uint160 sqrtPriceAtTail = TickMath.getSqrtRatioAtTick(tailTick);

        // todo: check if this is ever bigger than bondingAssetsRemaining
        // this does the nice calculation if token0 or token1 is the limiting asset in the pool
        uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceAtTail,
            TickMath.MIN_SQRT_RATIO,
            TickMath.MAX_SQRT_RATIO,
            isToken0 ? bondingAssetsRemaining : reserves,
            isToken0 ? reserves : bondingAssetsRemaining
        );

        // maybe we just hot calculate these
        int24 posTickLower = isToken0 ? binTickOnTickSpacing(TickMath.MIN_TICK, tickSpacing) : tailTick;
        int24 posTickUpper = isToken0 ? tailTick : binTickOnTickSpacing(TickMath.MAX_TICK, tickSpacing);
        require(tickLower < tickUpper, InvalidTickRangeMisordered(tickLower, tickUpper));

        // we may want to check this lol
        // TODO: require(tickLower < bondingAssetsRemaining);
        lpTail = lpPosition({ tickLower: tickLower, tickUpper: tickUpper, liquidity: lpTailLiquidity, salt: 0 });
    }

    // calculate the number of token amounts and the placement of each position
    // example: 1000 total tokens with 10 bins, they are linearlly spaced out
    // say the token price starts at tick 0, then we place a bin from
    // [0, 10], [1, 10], [2, 10], [3, 10] until [9, 10]
    // in each position, we place the same amount of tokens
    // i think avoids us keeping track of the positions fully and saves totalPositions SSTOREs
    // TODO can we set totalAmtToBeSold to so we can avoid calculating it?
    function calculateLogNormalDistribution(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        bool isToken0,
        uint16 totalPositions,
        uint256 totalAmtToBeSold
    ) public returns (lpPosition[] memory newPositions, uint256 reserves) {
        // this is the tick is moving from [0 to numPositions]
        int24 positionTick;

        // this is the distribution between the two ticks
        // TODO check directionality issues in any of the equations since its bidirectional
        int24 spreadBetweenTicksInPool = tickUpper - tickLower;

        int24 farTick = isToken0 ? tickUpper : tickLower;
        int24 closeTick = isToken0 ? tickLower : tickUpper;

        // load this one time
        // this has to be on a tickSpacing so it needs no check
        uint160 farSqrtPriceX96 = TickMath.getSqrtRatioAtTick(farTick);

        // how much of both token have we sold so far?
        uint256 totalAssetsSold;

        // this function may be easier to do as an accumulator now that i wrote all the math out
        for (uint256 i; i < totalPositions; i++) {
            // calculate the ticks position * 1/n to optimize the division
            // might be able to make this easier
            int24 sprBetweenBins = calculateInternalBinPosition(i, spreadBetweenTicksInPool, totalPositions);

            // this directionality i think is correct
            // internal referes to the tick position inside the pool
            // note: rounding here is intentional
            int24 binPositionInternal = isToken0 ? (tickLower + sprBetweenBins) : tickUpper - sprBetweenBins;

            // round the tick to the nearest bin
            binPositionInternal = binTickOnTickSpacing(binPositionInternal, tickSpacing);

            // this underflow can occur, but we just skip these ticks.
            // todo: check this logic and make sure it is safe and can even happen
            // avoids possible errors where we run a tick into the other side so have a 0 length position
            if (binPositionInternal != farTick) {
                uint160 binSqrtPriceX96 = TickMath.getSqrtRatioAtTick(binPositionInternal);

                // calculate the liquidity for the position that is (i * distance)/n of size
                // note: if totalAssets = 0 then we are skipping that calculation to calculate the position of each boundry
                // we dont save this value on following iterations
                uint128 liquidity;
                if (totalAmtToBeSold != 0) {
                    liquidity = isToken0
                        ? LiquidityAmounts.getLiquidityForAmount0(
                            binSqrtPriceX96, binSqrtPriceX96, totalAssetsSold / totalPositions
                        )
                        : LiquidityAmounts.getLiquidityForAmount1(
                            binSqrtPriceX96, binSqrtPriceX96, totalAmtToBeSold / totalPositions
                        );

                    // note: inside the TickMath function calls, the sqrtPrices will flip to the correct order
                    // todo: potentially test this and remove this function
                    // this may be removeable
                    // todo: check if we could avoid these calculations when removing positions
                    totalAssetsSold += (
                        isToken0
                            ? SqrtPriceMath.getAmount0Delta(
                                binSqrtPriceX96,
                                binSqrtPriceX96,
                                liquidity,
                                true // round for the amount of liquidity needed in this direction as it is more important to put too much than too little
                                    // we will also check against this value in a different function
                            )
                            : SqrtPriceMath.getAmount1Delta(
                                binSqrtPriceX96,
                                binSqrtPriceX96,
                                liquidity,
                                true // round for the amount of liquidity needed in this direction as it is more important to put too much than too little
                                    // we will also check against this value in a different function
                            )
                    );

                    // note: we keep track how the theoretical reserves amount at that time to then calculate the breakeven liquidity amount
                    // once we get to the end of the loop, we will know exactly how many of the reserve assets have been raised, and we can
                    // calculate the total amount of reserves after the endTick which makes swappers and LPs indifferent between Uniswap v2 (CPMM) and Uniswap v3 (CLAMM)
                    // we can then bond the tokens to the Uniswap v2 pool by moving them over to the Uniswap v3 pool whenever possible, but there is no rush as it goes up
                    reserves += (
                        isToken0
                            ? SqrtPriceMath.getAmount1Delta(
                                binSqrtPriceX96,
                                binSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                            : SqrtPriceMath.getAmount0Delta(
                                binSqrtPriceX96,
                                binSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                    );
                }
                // todo: check the direction of these ticks
                newPositions[i] = lpPosition({
                    tickLower: farSqrtPriceX96 < binSqrtPriceX96 ? farTick : binPositionInternal,
                    tickUpper: farSqrtPriceX96 < binSqrtPriceX96 ? binPositionInternal : farTick,
                    liquidity: liquidity,
                    salt: uint8(i + 1) // the 0 index = LP tail
                 });
            }
        }

        // we may have to avoid some positions in this case?
        // theoretically, we may just be able to check this when minting the positions as we can calculate the totalAmount sold and halt if needed?
        require(totalAssetsSold <= totalAmtToBeSold, CannotMintZeroLiquidity());
    }

    // todo: we can optimize this by checking the next value and then avoiding an extra mint if they are the same tl and tu
    function mintPositions(address asset, address numeraire, uint24 fee, address pool, lpPosition[] memory newPositions, uint16 numPositions) public {
        for (uint256 i; i < numPositions; i++) {
            IUniswapV3Pool(pool).mint(
                address(this),
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                newPositions[i].liquidity,
                abi.encode(CallbackData({ asset: asset, numeraire: numeraire, fee: fee }))
            );
        }
    }

    function checkPoolParams(int24 tick, int24 tickSpacing) public returns (bool) {
        require(tick % tickSpacing == 0, InvalidTickRange(tick, tickSpacing));
    }

    // TODO: should maxNumTokensToBond be in the initialize data
    // it means that the airlock controls it, which is good for security
    function initialize(
        address asset,
        address numeraire,
        uint256 maxShareToBeSold,
        uint256 maxShareToBond,
        bytes32,
        bytes calldata data
    ) external returns (address pool) {
        require(msg.sender == airlock, OnlyAirlock());

        InitData memory initData = abi.decode(data, (InitData));
        (uint24 fee, int24 tickLower, int24 tickUpper, uint16 numPositions) =
            (initData.fee, initData.tickLower, initData.tickUpper, initData.numPositions);

        require(tickLower < tickUpper, InvalidTickRangeMisordered(tickLower, tickUpper));
        // require(targetTick >= tickLower && targetTick <= tickUpper, InvalidTargetTick());


        int24 tickSpacing = factory.feeAmountTickSpacing(fee);
        require(tickSpacing != 0, InvalidFee(fee));
        checkTickSpacing(tickLower, tickSpacing);
        checkTickSpacing(tickUpper, tickSpacing);

        (address tokenA, address tokenB) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        // TODO: should we pass this or calculate it in the contract?
        uint256 numTokensToSell = FullMath.mulDiv(IERC20(asset).totalSupply(), maxShareToBeSold, 1e6);
        uint256 numTokensToBond = FullMath.mulDiv(IERC20(asset).totalSupply(), maxShareToBond, 1e6);

        pool = factory.getPool(tokenA, tokenB, fee);
        require(getState[pool].isInitialized == false, PoolAlreadyInitialized());

        bool isToken0 = asset == tokenA;

        if (pool == address(0)) {
            pool = factory.createPool(tokenA, tokenB, fee);
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(isToken0 ? tickLower : tickUpper);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        // 1 extra for the lp tail (which always exists)
        lpPosition[] memory newPositions = new lpPosition[](numPositions + 1);

        getState[pool] = PoolState({
            asset: asset,
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            isInitialized: true,
            isExited: false,
            numPositions: numPositions
        });

        // reserves = the amount of eventual reserves and lbpPositions are n number of positions that approx log normal liquidity distribution
        (lpPosition[] memory lbpPositions, uint256 reserves) =
            calculateLogNormalDistribution(tickLower, tickUpper, tickSpacing, isToken0, numPositions, numTokensToSell);
        
        // probably an easier way to do this
        for (uint256 i; i < numPositions; i++) {
            newPositions[i + 1] = lbpPositions[i];
        }
        newPositions[0] = calculatelpTail(numTokensToBond, tickLower, tickUpper, isToken0, reserves, tickSpacing);

        mintPositions(asset, numeraire, fee, pool, newPositions, numPositions);
    }

    // todo: we can optimize this by checking the next value and then avoiding an extra mint if they are the same tl and tu 
    // todo: we could also write a function that collapses the positions into as few mints as possible
    function burnPositionsMultiple(
        address pool,
        lpPosition[] memory newPositions,
        uint16 numPositions
    ) public returns (uint256 amount0, uint256 amount1) {
        uint256 posAmount0;
        uint256 posAmount1;
        for (uint256 i; i < numPositions; i++) {
            (posAmount0, posAmount1) = IUniswapV3Pool(pool).burn(
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                type(uint128).max
            );
            amount0 += posAmount0;
            amount1 += posAmount1;
        }
    }

    function exitLiquidity(
        address pool
    )
        external
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint256 fees0,
            uint256 balance0,
            address token1,
            uint256 fees1,
            uint256 balance1
        )
    {
        require(msg.sender == airlock, OnlyAirlock());
        require(getState[pool].isExited == false, PoolAlreadyExited());
        getState[pool].isExited = true;

        // todo: fix notation - tokenA and tokenB in initialize() but exitLiquidity() its token0 and token1
        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tick;
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();

        address asset = getState[pool].asset;
        int24 endingTick = asset != token0 ? getState[pool].tickLower : getState[pool].tickUpper;

        bool isToken0 = asset == token0;

        // todo: check if we should just read tickUpper and tickLower once
        int24 farTick = isToken0 ? getState[pool].tickUpper : getState[pool].tickLower;
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));

        uint16 numPositions = getState[pool].numPositions;

        // todo: make sure 0 totalAmtToBeSold is fine here
        // make sure reserves = 0 if totalAmtToBeSold = 0
        (lpPosition[] memory lbpPositions, uint256 reserves) = calculateLogNormalDistribution(
            getState[pool].tickLower, getState[pool].tickUpper, tickSpacing, isToken0, numPositions, 0
        );

        lpPosition[] memory newPositions = new lpPosition[](numPositions + 1);
        for (uint256 i; i < numPositions; i++) {
            newPositions[i + 1] = lbpPositions[i];
        }
        newPositions[0] = calculatelpTail(0, getState[pool].tickLower, getState[pool].tickUpper, isToken0, reserves, tickSpacing);

        (uint256 amount0, uint256 amount1) = burnPositionsMultiple(pool, newPositions, numPositions);
        (balance0, balance1) = IUniswapV3Pool(pool).collect(
            address(this), getState[pool].tickLower, getState[pool].tickUpper, type(uint128).max, type(uint128).max
        );

        // todo: check this is in tokens, not in liquidity
        fees0 = balance0 - amount0;
        fees1 = balance1 - amount1;

        // TODO: Use safeTransfer instead
        ERC20(token0).transfer(msg.sender, balance0);
        ERC20(token1).transfer(msg.sender, balance1);

        //TODO: transfer fees to the multsig?
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);
        
        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).transferFrom(airlock, pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }
}
