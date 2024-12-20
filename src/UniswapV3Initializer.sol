/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "v4-core/test/utils/LiquidityAmounts.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

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
error InvalidTickRange500(int24 tickLower, int24 tickUpper);
error InvalidTickRange3000(int24 tickLower, int24 tickUpper);
error InvalidTickRange10000(int24 tickLower, int24 tickUpper);

struct InitData {
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    int24 targetTick;
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
    int24 targetTick;
    uint128 liquidityDelta;
    bool isInitialized;
    bool isExited;
}

contract UniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback {
    address public immutable airlock;
    IUniswapV3Factory public immutable factory;

    mapping(address pool => PoolState state) public getState;

    constructor(address airlock_, IUniswapV3Factory factory_) {
        airlock = airlock_;
        factory = factory_;
    }

    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32,
        bytes calldata data
    ) external returns (address pool) {
        require(msg.sender == airlock, OnlyAirlock());

        InitData memory initData = abi.decode(data, (InitData));
        (uint24 fee, int24 tickLower, int24 tickUpper, int24 targetTick) =
            (initData.fee, initData.tickLower, initData.tickUpper, initData.targetTick);

        require(tickLower < tickUpper, InvalidTickRangeMisordered(tickLower, tickUpper));
        require(targetTick >= tickLower && targetTick <= tickUpper, InvalidTargetTick());

        if (fee == 3000) {
            require(tickLower % 60 == 0 && tickUpper % 60 == 0, InvalidTickRange3000(tickLower, tickUpper));
        } else if (fee == 10_000) {
            require(tickLower % 200 == 0 && tickUpper % 200 == 0, InvalidTickRange10000(tickLower, tickUpper));
        } else if (fee == 500) {
            require(tickLower % 10 == 0 && tickUpper % 10 == 0, InvalidTickRange500(tickLower, tickUpper));
        } else {
            revert InvalidFee(fee);
        }

        (address tokenA, address tokenB) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = factory.getPool(tokenA, tokenB, fee);
        require(getState[pool].isInitialized == false, PoolAlreadyInitialized());

        bool isToken0 = asset == tokenA;

        if (pool == address(0)) {
            pool = factory.createPool(tokenA, tokenB, fee);
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? tickUpper : tickLower);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }

        uint128 amount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            isToken0 ? numTokensToSell : 0,
            isToken0 ? 0 : numTokensToSell
        );

        require(amount > 0, CannotMintZeroLiquidity());

        getState[pool] = PoolState({
            asset: asset,
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: amount,
            targetTick: targetTick,
            isInitialized: true,
            isExited: false
        });

        IUniswapV3Pool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            abi.encode(CallbackData({ asset: asset, numeraire: numeraire, fee: fee }))
        );
    }

    function exitLiquidity(
        address pool
    )
        external
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
        require(msg.sender == airlock, OnlyAirlock());
        require(getState[pool].isExited == false, PoolAlreadyExited());
        getState[pool].isExited = true;

        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        int24 tick;
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();

        address asset = getState[pool].asset;
        int24 targetTick = getState[pool].targetTick;
        int24 endingTick = asset != token0 ? getState[pool].tickLower : getState[pool].tickUpper;

        require(tick != endingTick, CannotMigrateOutOfRange(endingTick, tick));
        require(
            asset == token0 ? tick <= targetTick : tick >= targetTick, CannotMigrateInsufficientTick(targetTick, tick)
        );

        // We do this first call to track the fees separately
        (,,, fees0, fees1) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(this), getState[pool].tickLower, getState[pool].tickUpper))
        );

        IUniswapV3Pool(pool).burn(getState[pool].tickLower, getState[pool].tickUpper, getState[pool].liquidityDelta);

        // Calling this again allows us to get the sum of the fees + tokens from the actual position
        (,,, balance0, balance1) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(this), getState[pool].tickLower, getState[pool].tickUpper))
        );

        // TODO: I think we can save some gas by requesting type(uint128).max instead of specific amounts
        IUniswapV3Pool(pool).collect(
            address(this), getState[pool].tickLower, getState[pool].tickUpper, balance0, balance1
        );

        // TODO: Use safeTransfer instead
        ERC20(token0).transfer(msg.sender, balance0);
        ERC20(token1).transfer(msg.sender, balance1);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);
        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).transferFrom(airlock, pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }
}
