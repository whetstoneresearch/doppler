/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract UniswapV2Migrator {
    IUniswapV2Factory public immutable factory;
    IUniswapV2Router02 public immutable router;

    constructor(IUniswapV2Factory factory_, IUniswapV2Router02 router_) {
        factory = factory_;
        router = router_;
    }

    function migrate(address asset, address numeraire) external returns (address pool) {
        // TODO: Move the liquidity into this contract
        (address tokenA, address tokenB) = asset > numeraire ? (numeraire, asset) : (asset, numeraire);
        pool = factory.createPair(asset, numeraire);
        // TODO: Put the liquidity into the pool
        router.addLiquidity(tokenA, tokenB, 0, 0, 0, 0, msg.sender, block.timestamp);
    }
}
