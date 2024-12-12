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
error CannotMigrate(int24 expectedTick, int24 currentTick);

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

struct PoolState {
    address asset;
    address numeraire;
    uint256 mininmumProceeds;
    uint256 maximumProceeds;
    uint256 startingTime;
    uint256 endingTime;
    int24 tickLower;
    int24 tickUpper;
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

        (uint24 fee, int24 tickLower, int24 tickUpper) = abi.decode(data, (uint24, int24, int24));
        (address tokenA, address tokenB) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = factory.getPool(tokenA, tokenB, fee);
        require(getState[pool].isInitialized == false, PoolAlreadyInitialized());

        if (pool == address(0)) {
            pool = factory.createPool(tokenA, tokenB, fee);
        }

        uint160 sqrtPriceX96 =
            asset == tokenA ? TickMath.getSqrtPriceAtTick(tickLower) : TickMath.getSqrtPriceAtTick(tickUpper);

        // TODO: This will fail if the pool is already initialized
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        uint128 amount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            asset == tokenA ? numTokensToSell : 0,
            asset == tokenA ? 0 : numTokensToSell
        );

        getState[pool] = PoolState({
            asset: asset,
            numeraire: numeraire,
            mininmumProceeds: 0,
            maximumProceeds: 0,
            startingTime: 0,
            endingTime: 0,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: amount,
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
    ) external returns (address token0, uint256 amount0, address token1, uint256 amount1) {
        require(msg.sender == airlock, OnlyAirlock());
        require(getState[pool].isExited == false, PoolAlreadyExited());
        getState[pool].isExited = true;

        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 endingTick = getState[pool].asset != token0 ? getState[pool].tickLower : getState[pool].tickUpper;

        // TODO: I think it's possible to move the current tick above or under our current tick range
        require(tick == endingTick, CannotMigrate(endingTick, tick));

        (amount0, amount1) =
            IUniswapV3Pool(pool).burn(getState[pool].tickLower, getState[pool].tickUpper, getState[pool].liquidityDelta);
        (,,, uint128 tokensOwed0, uint128 tokensOwed1) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(this), getState[pool].tickLower, getState[pool].tickUpper))
        );
        IUniswapV3Pool(pool).collect(
            address(this), getState[pool].tickLower, getState[pool].tickUpper, tokensOwed0, tokensOwed1
        );

        // TODO: Use safeTransfer instead
        ERC20(token0).transfer(msg.sender, tokensOwed0);
        ERC20(token1).transfer(msg.sender, tokensOwed1);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);
        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).transferFrom(airlock, pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }
}
