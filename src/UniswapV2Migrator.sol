/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IMigrator } from "src/interfaces/IMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

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

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 */
contract UniswapV2Migrator is IMigrator {
    using FixedPointMathLib for uint256;

    IUniswapV2Factory public immutable factory;
    IUniswapV2Router02 public immutable router;

    mapping(address token0 => mapping(address token1 => address pool)) public getPool;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     * @param router_  Address of the Uniswap V2 router
     */
    constructor(IUniswapV2Factory factory_, IUniswapV2Router02 router_) {
        factory = factory_;
        router = router_;
    }

    function createPool(address token0, address token1) external returns (address) {
        if (token0 == address(0)) token0 = router.WETH();

        address pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool = factory.createPair(token0, token1);
        }

        getPool[token0][token1] = pool;

        return pool;
    }

    /**
     * @notice Migrates the liquidity into a Uniswap V2 pool
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens
     * @return pool Address of the Uniswap V2 pool
     * @return liquidity Amount of liquidity tokens minted
     */
    function migrate(
        address token0,
        address token1,
        uint256 price,
        address recipient,
        bytes memory
    ) external payable returns (address pool, uint256 liquidity) {
        uint256 balance0 = token0 == address(0) ? address(this).balance : ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        pool = getPool[token0 == address(0) ? router.WETH() : token0][token1];

        uint256 amount0 = price.mulWadDown(balance1);
        uint256 amount1 = balance0.divWadDown(price);

        if (amount0 > balance0) {
            amount0 = balance0;
            amount1 = amount0.divWadDown(price);
        } else if (amount1 > balance1) {
            amount1 = balance1;
            amount0 = price.mulWadDown(amount1);
        }

        ERC20(token1).approve(address(router), amount1);

        if (token0 == address(0)) {
            (,, liquidity) = router.addLiquidityETH{ value: amount0 }(token1, amount1, 0, 0, recipient, block.timestamp);
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
            if (address(this).balance > 0) SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        } else {
            ERC20(token0).approve(address(router), amount0);
            (,, liquidity) = router.addLiquidity(token0, token1, amount0, amount1, 0, 0, msg.sender, block.timestamp);
            ERC20(token0).approve(address(router), 0);
            uint256 dust0 = ERC20(token0).balanceOf(address(this));
            if (dust0 > 0) SafeTransferLib.safeTransfer(ERC20(token0), recipient, dust0);
        }

        ERC20(token1).approve(address(router), 0);
        uint256 dust1 = ERC20(token1).balanceOf(address(this));
        if (dust1 > 0) SafeTransferLib.safeTransfer(ERC20(token1), recipient, dust1);
    }
}
