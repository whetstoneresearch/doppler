/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { TickMath } from "lib/v4-core/src/libraries/TickMath.sol";
// import { LiquidityAmounts } from "@v3-periphery/libraries/LiquidityAmounts.sol";
import { LiquidityAmounts } from "lib/v4-core/test/utils/LiquidityAmounts.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

error OnlyAirlock();
error OnlyPool();
error PoolAlreadyInitialized();

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

contract UniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback {
    address public immutable airlock;
    IUniswapV3Factory public immutable factory;

    mapping(address pool => bool status) public isInitialized;

    constructor(address airlock_, IUniswapV3Factory factory_) {
        airlock = airlock_;
        factory = factory_;
    }

    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes memory data
    ) external returns (address pool) {
        require(msg.sender == airlock, OnlyAirlock());

        (address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (address, address, uint24, uint160, int24, int24));

        pool = factory.getPool(tokenA, tokenB, fee);

        if (pool == address(0)) {
            pool = factory.createPool(tokenA, tokenB, fee);
        }

        // TODO: This will fail if the pool is already initialized
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        uint128 amount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            asset == tokenA ? numTokensToSell : 0,
            asset == tokenA ? 0 : numTokensToSell
        );

        IUniswapV3Pool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            abi.encode(CallbackData({ asset: asset, numeraire: tokenA == asset ? tokenB : tokenA, fee: fee }))
        );
    }

    function exitLiquidity(
        address asset
    ) external returns (address token0, address token1, uint256 price) { }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);
        require(msg.sender == pool, OnlyPool());

        require(isInitialized[pool] == false, PoolAlreadyInitialized());
        isInitialized[pool] = true;

        ERC20(callbackData.asset).transfer(pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }
}
