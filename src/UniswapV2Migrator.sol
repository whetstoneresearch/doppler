// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { MigrationMath } from "src/libs/MigrationMath.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV2Migrator is ILiquidityMigrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    IUniswapV2Factory public immutable factory;
    IWETH public immutable weth;
    UniswapV2Locker public immutable locker;

    receive() external payable onlyAirlock { }

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        IUniswapV2Router02 router,
        address owner
    ) ImmutableAirlock(airlock_) {
        factory = factory_;
        weth = IWETH(payable(router.WETH()));
        locker = new UniswapV2Locker(airlock_, factory, this, owner);
    }

    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        return _initialize(asset, numeraire, liquidityMigratorData);
    }

    /**
     * @notice Migrates the liquidity into a Uniswap V2 pool
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens
     */
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        return _migrate(sqrtPriceX96, token0, token1, recipient);
    }

    function _initialize(address asset, address numeraire, bytes calldata) internal virtual returns (address) {
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        if (token0 == address(0)) token0 = address(weth);

        address pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool = factory.createPair(token0, token1);
        }

        return pool;
    }

    function _migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) internal virtual returns (uint256 liquidity) {
        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: address(this).balance }();
            balance0 = weth.balanceOf(address(this));
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPriceX96);

        if (depositAmount1 > balance1) {
            (, depositAmount1) = MigrationMath.computeDepositAmounts(depositAmount0, balance1, sqrtPriceX96);
        } else {
            (depositAmount0,) = MigrationMath.computeDepositAmounts(balance0, depositAmount1, sqrtPriceX96);
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
        locker.receiveAndLock(pool, recipient);

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
