/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { WETH as IWETH } from "solmate/src/tokens/WETH.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
}

interface IUniswapV2Pair {
    function mint(
        address to
    ) external returns (uint256 liquidity);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

error NotAirlock();
error SenderNotRouter();

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 */
contract UniswapV2Migrator is ILiquidityMigrator {
    using FullMath for uint256;
    using SafeTransferLib for ERC20;

    IUniswapV2Factory public immutable factory;
    IUniswapV2Router02 public immutable router;
    IWETH public immutable weth;
    address public immutable airlock;

    mapping(address token0 => mapping(address token1 => address pool)) public getPool;

    receive() external payable {
        if (msg.sender != address(router)) revert SenderNotRouter();
    }

    /**
     * @param factory_ Address of the Uniswap V2 factory
     * @param router_  Address of the Uniswap V2 router
     */
    constructor(address airlock_, IUniswapV2Factory factory_, IUniswapV2Router02 router_) {
        airlock = airlock_;
        factory = factory_;
        router = router_;
        weth = IWETH(payable(router.WETH()));
    }

    function create(address token0, address token1, bytes memory) external returns (address) {
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
     * @param price Price of token0 in terms of token1 (Q96 format)
     * @param recipient Address receiving the liquidity pool tokens
     */
    function migrate(address token0, address token1, uint256 price, address recipient, bytes memory) external payable {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        uint256 balance0;

        if (token0 == address(0)) {
            balance0 = address(this).balance;
            token0 = address(weth);
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (balance0, balance1) = (balance1, balance0);
            price = FixedPoint96.Q96 / price;
        }

        // Pool was created beforehand along the asset token deployment
        address pool = getPool[token0][token1];

        uint256 amount0 = price.mulDiv(balance1, FixedPoint96.Q96);
        uint256 amount1 = balance0.mulDiv(FixedPoint96.Q96, price);

        if (amount0 > balance0) {
            amount0 = balance0;
            amount1 = amount0.mulDiv(FixedPoint96.Q96, price);
        } else if (amount1 > balance1) {
            amount1 = balance1;
            amount0 = price.mulDiv(amount1, FixedPoint96.Q96);
        }

        if (token0 == address(weth)) {
            weth.deposit{ value: amount0 }();
        } else if (token1 == address(weth)) {
            weth.deposit{ value: amount1 }();
        }

        ERC20(token0).safeTransfer(pool, amount0);
        ERC20(token1).safeTransfer(pool, amount1);

        IUniswapV2Pair(pool).mint(recipient);

        if (address(this).balance > 0) SafeTransferLib.safeTransferETH(recipient, address(this).balance);

        uint256 dust0 = ERC20(token0).balanceOf(address(this));
        if (dust0 > 0) SafeTransferLib.safeTransfer(ERC20(token0), recipient, dust0);

        uint256 dust1 = ERC20(token1).balanceOf(address(this));
        if (dust1 > 0) SafeTransferLib.safeTransfer(ERC20(token1), recipient, dust1);
    }
}
