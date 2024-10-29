/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IMigrator} from "src/interfaces/IMigrator.sol";

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
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract UniswapV2Migrator is IMigrator {
    IUniswapV2Factory public immutable factory;
    IUniswapV2Router02 public immutable router;

    constructor(IUniswapV2Factory factory_, IUniswapV2Router02 router_) {
        factory = factory_;
        router = router_;
    }

    function migrate(
        address asset,
        address numeraire,
        uint256 amountAsset,
        uint256 amountNumeraire,
        address recipient,
        bytes memory
    ) external payable returns (address pool, uint256 liquidity) {
        (address tokenA, address tokenB) = asset > numeraire ? (numeraire, asset) : (asset, numeraire);

        ERC20(asset).transferFrom(msg.sender, address(this), amountAsset);
        ERC20(numeraire).transferFrom(msg.sender, address(this), amountNumeraire);

        pool = factory.getPair(tokenA, tokenB);

        if (pool == address(0)) {
            pool = factory.createPair(tokenA, tokenB);
        }

        pool = factory.createPair(asset, numeraire);

        if (numeraire == address(0)) {
            (,, liquidity) =
                router.addLiquidityETH{value: amountNumeraire}(asset, amountAsset, 0, 0, recipient, block.timestamp);
        } else {
            (,, liquidity) = router.addLiquidity(tokenA, tokenB, 0, 0, 0, 0, msg.sender, block.timestamp);
        }

        // TODO: Also transfer the dust tokens to the `recipient` address?
        ERC20(pool).transfer(recipient, liquidity);
    }
}
