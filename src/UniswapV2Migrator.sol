/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "solmate/src/tokens/WETH.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
}

interface IUniswapV2Pair {
    function mint(
        address to
    ) external returns (uint256 liquidity);
    function balanceOf(
        address owner
    ) external view returns (uint256);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

error SenderNotAirlock();

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV2Migrator is ILiquidityMigrator {
    using SafeTransferLib for ERC20;
    using FullMath for uint256;
    using FullMath for uint160;

    IUniswapV2Factory public immutable factory;
    IWETH public immutable weth;
    address public immutable airlock;

    mapping(address token0 => mapping(address token1 => address pool)) public getPool;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(address airlock_, IUniswapV2Factory factory_, IUniswapV2Router02 router) {
        airlock = airlock_;
        factory = factory_;
        weth = IWETH(payable(router.WETH()));
    }

    function initialize(address asset, address numeraire, bytes calldata) external returns (address) {
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        if (token0 == address(0)) token0 = address(weth);
        if (token0 > token1) (token0, token1) = (token1, token0);

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
     */
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        address recipient
    ) external payable returns (uint256 liquidity) {
        if (msg.sender != airlock) {
            revert SenderNotAirlock();
        }

        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: amount0 }();
        }

        uint256 price = sqrtPriceX96.mulDiv(sqrtPriceX96, FixedPoint96.Q96);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0, amount1) = (amount1, amount0);
            price = FixedPoint96.Q96.mulDiv(FixedPoint96.Q96, price);
        }

        uint256 depositAmount0 = amount1.mulDiv(price, FixedPoint96.Q96);
        uint256 depositAmount1 = amount0.mulDiv(FixedPoint96.Q96, price);

        if (depositAmount1 > amount1) {
            depositAmount1 = amount1;
            depositAmount0 = depositAmount1.mulDiv(price, FixedPoint96.Q96);
        } else if (depositAmount0 > amount0) {
            depositAmount0 = amount0;
            depositAmount1 = depositAmount0.mulDiv(FixedPoint96.Q96, price);
        }

        // Pool was created beforehand along the asset token deployment
        address pool = getPool[token0][token1];

        ERC20(token0).safeTransfer(pool, depositAmount0);
        ERC20(token1).safeTransfer(pool, depositAmount1);

        liquidity = IUniswapV2Pair(pool).mint(recipient);

        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        uint256 dust0 = ERC20(token0).balanceOf(address(this));
        if (dust0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), recipient, dust0);
        }

        uint256 dust1 = ERC20(token1).balanceOf(address(this));
        if (dust1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), recipient, dust1);
        }
    }
}
