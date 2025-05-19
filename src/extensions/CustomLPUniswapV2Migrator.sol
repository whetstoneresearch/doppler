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
import { CustomLPUniswapV2Locker } from "src/extensions/CustomLPUniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant from Long
 * @notice An extension built on top of UniswapV2Migrator to enable locking LP for a custom period
 */
contract CustomLPUniswapV2Migrator is ILiquidityMigrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @dev Constant used to increase precision during calculations
    uint256 constant WAD = 1 ether;
    /// @dev Maximum amount of liquidity that can be allocated to `lpAllocationRecipient` (% expressed in WAD i.e. max 5%)
    uint256 constant MAX_CUSTOM_LP_WAD = 0.05 ether;
    /// @dev Minimum lock up period for the custom LP allocation
    uint256 public constant MIN_LOCK_PERIOD = 30 days;

    IUniswapV2Factory public immutable FACTORY;
    IWETH public immutable WETH;
    CustomLPUniswapV2Locker public immutable CUSTOM_LP_LOCKER;

    /// @dev Lock up period for the LP tokens allocated to `customLPRecipient`
    uint32 public lockUpPeriod;
    /// @dev Allow custom allocation of LP tokens other than `LP_TO_LOCK_WAD` (% expressed in WAD)
    uint64 public customLPWad;
    /// @dev Address of the recipient of the custom LP allocation
    address public customLPRecipient;

    /// @notice Thrown when the custom LP allocation exceeds `MAX_CUSTOM_LP_WAD`
    error MaxCustomLPWadExceeded();
    /// @notice Thrown when the recipient is not an EOA
    error RecipientNotEOA();
    /// @notice Thrown when the lock up period is less than `MIN_LOCK_PERIOD`
    error LessThanMinLockPeriod();
    /// @notice Thrown when the input is zero
    error InvalidInput();

    receive() external payable onlyAirlock { }

    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        IUniswapV2Router02 router,
        address owner
    ) ImmutableAirlock(airlock_) {
        FACTORY = factory_;
        WETH = IWETH(payable(router.WETH()));
        CUSTOM_LP_LOCKER = new CustomLPUniswapV2Locker(airlock_, factory_, this, owner);
    }

    /**
     * @notice Initializes the migrator
     * @param asset Address of the asset token
     * @param numeraire Address of the numeraire token
     * @param liquidityMigratorData Encoded data containing custom LP allocation parameters
     * @return pool Address of the created Uniswap V2 pool
     */
    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        if (liquidityMigratorData.length > 0) {
            (uint64 customLPWad_, address customLPRecipient_, uint32 lockUpPeriod_) =
                abi.decode(liquidityMigratorData, (uint64, address, uint32));
            require(customLPWad_ > 0 && customLPRecipient_ != address(0), InvalidInput());
            require(customLPWad_ <= MAX_CUSTOM_LP_WAD, MaxCustomLPWadExceeded());
            // initially only allow EOA to receive the lp allocation
            require(customLPRecipient_.code.length == 0, RecipientNotEOA());
            require(lockUpPeriod_ >= MIN_LOCK_PERIOD, LessThanMinLockPeriod());

            customLPWad = customLPWad_;
            customLPRecipient = customLPRecipient_;
            lockUpPeriod = lockUpPeriod_;
        }

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        if (token0 == address(0)) token0 = address(WETH);

        address pool = FACTORY.getPair(token0, token1);

        if (pool == address(0)) {
            pool = FACTORY.createPair(token0, token1);
        }

        return pool;
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
        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            token0 = address(WETH);
            WETH.deposit{ value: address(this).balance }();
            balance0 = WETH.balanceOf(address(this));
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
        address pool = FACTORY.getPair(token0, token1);

        ERC20(token0).safeTransfer(pool, depositAmount0);
        ERC20(token1).safeTransfer(pool, depositAmount1);

        // Custom LP allocation: (n <= `MAX_CUSTOM_LP_WAD`)% to `customLPRecipient` after `lockUpPeriod`, rest will be sent to timelock
        liquidity = IUniswapV2Pair(pool).mint(address(this));
        uint256 customLiquidityToLock = liquidity * customLPWad / WAD;
        uint256 liquidityToTransfer = liquidity - customLiquidityToLock;

        IUniswapV2Pair(pool).transfer(recipient, liquidityToTransfer);
        IUniswapV2Pair(pool).transfer(address(CUSTOM_LP_LOCKER), customLiquidityToLock);
        CUSTOM_LP_LOCKER.receiveAndLock(pool, customLPRecipient, lockUpPeriod);

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
