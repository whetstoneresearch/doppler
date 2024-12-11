/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
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

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 */
contract UniswapV2Migrator is ILiquidityMigrator {
    using SafeTransferLib for ERC20;

    IUniswapV2Factory public immutable factory;
    IUniswapV2Router02 public immutable router;
    IWETH public immutable weth;
    address public immutable airlock;

    mapping(address token0 => mapping(address token1 => address pool)) public getPool;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(address airlock_, IUniswapV2Factory factory_) {
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
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        address recipient,
        bytes calldata
    ) external payable {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        if (token0 == address(0)) {
            token0 = address(weth);
        }

        // Pool was created beforehand along the asset token deployment
        address pool = getPool[token0][token1];

        if (token0 == address(weth)) {
            weth.deposit{ value: amount0 }();
        } else if (token1 == address(weth)) {
            weth.deposit{ value: amount1 }();
        }

        ERC20(token0).safeTransfer(pool, amount0);
        ERC20(token1).safeTransfer(pool, amount1);

        IUniswapV2Pair(pool).mint(recipient);

        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        // TODO: Not sure if this is necessary anymore
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
