// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { WETH } from "@solady/tokens/WETH.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ProceedsSplitter, SplitConfiguration } from "src/base/ProceedsSplitter.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV2MigratorSplit is ILiquidityMigrator, ImmutableAirlock, ProceedsSplitter {
    using SafeTransferLib for ERC20;

    /// @notice Address of the Uniswap V2 factory
    IUniswapV2Factory public immutable factory;

    /// @notice Address of the WETH contract
    WETH public immutable weth;

    /// @notice Address of the Uniswap V2 locker
    UniswapV2Locker public immutable locker;

    /// @notice Fallback function to receive ETH
    receive() external payable onlyAirlock { }

    /**
     * @param airlock_ Address of the Airlock contract
     * @param factory_ Address of the Uniswap V2 factory
     * @param topUpDistributor Address of the TopUpDistributor contract
     * @param weth_ Address of the WETH contract
     */
    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        TopUpDistributor topUpDistributor,
        address weth_
    ) ImmutableAirlock(airlock_) ProceedsSplitter(topUpDistributor) {
        factory = factory_;
        weth = WETH(payable(weth_));
        locker = new UniswapV2Locker(airlock_, this);
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

    function _initialize(address asset, address numeraire, bytes calldata data) internal virtual returns (address) {
        if (numeraire == address(0)) {
            numeraire = address(weth);
        }

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        address pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool = factory.createPair(token0, token1);
        }

        (address recipient, uint256 share) = abi.decode(data, (address, uint256));

        if (share > 0) {
            _setSplit(
                token0, token1, SplitConfiguration({ recipient: recipient, isToken0: asset < numeraire, share: share })
            );
        }

        return pool;
    }

    function _migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) internal virtual returns (uint256 liquidity) {
        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: address(this).balance }();
            (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        }
        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (splitConfigurationOf[token0][token1].share > 0) {
            (balance0, balance1) = _distributeSplit(token0, token1, balance0, balance1);
        }

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPriceX96);

        if (depositAmount1 > balance1) {
            (, depositAmount1) = MigrationMath.computeDepositAmounts(depositAmount0, balance1, sqrtPriceX96);
        } else {
            (depositAmount0,) = MigrationMath.computeDepositAmounts(balance0, depositAmount1, sqrtPriceX96);
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
