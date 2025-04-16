// SPDX-License-Identifier: MIT
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
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { CustomLPUniswapV2Locker } from "src/extensions/CustomLPUniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @notice UniswapV2Migrator with custom LP allocation feature enabled
 */
contract CustomLPUniswapV2Migrator is UniswapV2Migrator {
    using SafeTransferLib for ERC20;

    /// @dev Constant used to increase precision during calculations
    uint256 constant WAD = 1 ether;
    /// @dev Liquidity to lock (% expressed in WAD)
    uint256 constant LP_TO_LOCK_WAD = 0.05 ether;
    /// @dev Maximum amount of liquidity that can be allocated to `lpAllocationRecipient` (% expressed in WAD)
    uint256 constant MAX_CUSTOM_LP_WAD = 0.02 ether;

    CustomLPUniswapV2Locker public immutable customLPLocker;

    /// @dev Lock up period for the LP tokens allocated to `customLPRecipient`
    uint32 public lockUpPeriod;
    /// @dev Allow custom allocation of LP tokens other than `LP_TO_LOCK_WAD` (% expressed in WAD)
    uint64 public customLPWad;
    /// @dev Address of the recipient of the custom LP allocation
    address public customLPRecipient;

    error MaxCustomLPWadExceeded();
    error RecipientNotEOA();
    error InvalidInput();

    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        IUniswapV2Router02 router,
        address owner
    ) UniswapV2Migrator(airlock_, factory_, router, owner) {
        customLPLocker = new CustomLPUniswapV2Locker(airlock_, factory_, this, owner);
    }

    function _initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) internal override returns (address) {
        if (liquidityMigratorData.length > 0) {
            (uint64 customLPWad_, address customLPRecipient_, uint32 lockUpPeriod_) =
                abi.decode(liquidityMigratorData, (uint64, address, uint32));
            require(customLPWad_ > 0 && customLPRecipient_ != address(0), InvalidInput());
            require(customLPWad_ <= MAX_CUSTOM_LP_WAD, MaxCustomLPWadExceeded());
            // initially only allow EOA to receive the lp allocation
            require(customLPRecipient_.code.length == 0, RecipientNotEOA());

            customLPWad = customLPWad_;
            customLPRecipient = customLPRecipient_;
            lockUpPeriod = lockUpPeriod_;
        }

        return super._initialize(asset, numeraire, liquidityMigratorData);
    }

    function _migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) internal override returns (uint256 liquidity) {
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

        // Custom LP allocation - 5% to locker, (n <= `MAX_CUSTOM_LP_WAD`)% to `customLPRecipient`, rest to timelock
        liquidity = IUniswapV2Pair(pool).mint(address(this));
        uint256 liquidityToLock = liquidity * LP_TO_LOCK_WAD / WAD;
        uint256 customLiquidityToLock = liquidity * customLPWad / WAD;
        uint256 liquidityToTransfer = liquidity - liquidityToLock - customLiquidityToLock;

        IUniswapV2Pair(pool).transfer(recipient, liquidityToTransfer);
        IUniswapV2Pair(pool).transfer(address(locker), liquidityToLock);
        IUniswapV2Pair(pool).transfer(address(customLPLocker), customLiquidityToLock);
        locker.receiveAndLock(pool, recipient);
        customLPLocker.receiveAndLock(pool, customLPRecipient, lockUpPeriod);

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
