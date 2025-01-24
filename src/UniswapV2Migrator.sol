// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";

/// @notice Thrown when the sender is not the Airlock contract
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
    UniswapV2Locker public locker;

    mapping(address token0 => mapping(address token1 => address pool)) public getPool;
    mapping(address pool => address) public getAsset;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(address airlock_, IUniswapV2Factory factory_, IUniswapV2Router02 router, address owner) {
        airlock = airlock_;
        factory = factory_;
        weth = IWETH(payable(router.WETH()));
        locker = new UniswapV2Locker(Airlock(payable(airlock)), factory, this, owner);
    }

    function initialize(address asset, address numeraire, bytes calldata) external returns (address) {
        require(msg.sender == airlock, SenderNotAirlock());

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        if (token0 == address(0)) token0 = address(weth);
        if (token0 > token1) (token0, token1) = (token1, token0);

        address pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool = factory.createPair(token0, token1);
        }

        // todo: can we remove this check for the pool?
        getPool[token0][token1] = pool;
        getAsset[pool] = asset;

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
        address token1,
        address recipient
    ) external payable returns (uint256 liquidity) {
        require(msg.sender == airlock, SenderNotAirlock());

        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: address(this).balance }();
            balance0 = weth.balanceOf(address(this));
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        uint256 price = sqrtPriceX96.mulDiv(sqrtPriceX96, FixedPoint96.Q96);

        uint256 depositAmount0 = balance1.mulDiv(FixedPoint96.Q96, price);
        uint256 depositAmount1 = balance0.mulDiv(price, FixedPoint96.Q96);

        if (depositAmount1 > balance1) {
            depositAmount1 = balance1;
            depositAmount0 = depositAmount0;
        } else if (depositAmount0 > balance0) {
            depositAmount0 = balance0;
            depositAmount1 = depositAmount1;
        }

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (depositAmount0, depositAmount1) = (depositAmount1, depositAmount0);
        }

        // Pool was created beforehand along the asset token deployment
        address pool = factory.getPair(token0, token1);

        ERC20(token0).safeTransfer(pool, depositAmount0);
        ERC20(token1).safeTransfer(pool, depositAmount1);

        liquidity = IUniswapV2Pair(pool).mint(address(this));
        uint256 liquidityToLock = liquidity / 20;
        IUniswapV2Pair(pool).transfer(recipient, liquidity - liquidityToLock);
        IUniswapV2Pair(pool).transfer(address(locker), liquidityToLock);
        locker.receiveAndLock(pool);

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
