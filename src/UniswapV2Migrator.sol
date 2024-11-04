/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IMigrator } from "src/interfaces/IMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";

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
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address recipient,
        bytes memory
    ) external payable returns (address pool, uint256 liquidity) {
        pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool =
                factory.createPair(token0 == address(0) ? 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 : token0, token1);
        }

        if (token0 != address(0)) ERC20(token0).approve(address(router), amount0);
        ERC20(token1).approve(address(router), amount1);

        if (token0 == address(0)) {
            (,, liquidity) = router.addLiquidityETH{ value: amount0 }(token1, amount0, 0, 0, recipient, block.timestamp);
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        } else {
            ERC20(token0).approve(address(router), amount0);
            (,, liquidity) = router.addLiquidity(token0, token1, 0, 0, 0, 0, msg.sender, block.timestamp);
            SafeTransferLib.safeTransfer(ERC20(token0), recipient, ERC20(token0).balanceOf(address(this)));
        }

        SafeTransferLib.safeTransfer(ERC20(token1), recipient, ERC20(token1).balanceOf(address(this)));
    }
}
