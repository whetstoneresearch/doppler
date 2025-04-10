// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

library MigrationMath {
    using FullMath for uint256;
    using FullMath for uint160;

    /**
     * @dev Computes the amounts for an initial Uniswap V2 pool deposit.
     * @param balance0 Current balance of token0
     * @param balance1 Current balance of token1
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @return depositAmount0 Amount of token0 to deposit
     * @return depositAmount1 Amount of token1 to deposit
     */
    function computeDepositAmounts(
        uint256 balance0,
        uint256 balance1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 depositAmount0, uint256 depositAmount1) {
        // Stolen from https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol#L57
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            depositAmount0 = balance1.mulDiv(1 << 192, ratioX192);
            depositAmount1 = balance0.mulDiv(ratioX192, 1 << 192);
        } else {
            uint256 ratioX128 = sqrtPriceX96.mulDiv(sqrtPriceX96, 1 << 64);
            depositAmount0 = balance1.mulDiv(1 << 128, ratioX128);
            depositAmount1 = balance0.mulDiv(ratioX128, 1 << 128);
        }
    }
}

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V2 pool
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV2Migrator is ILiquidityMigrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @dev Constant used to increase precision during calculations
    uint256 constant WAD = 1 ether;
    /// @dev Liquidity to lock (% expressed in WAD)
    uint256 constant LP_TO_LOCK_WAD = 0.05 ether;
    /// @dev Maximum amount of liquidity that can be allocated to `lpAllocationRecipient` (% expressed in WAD)
    uint256 constant MAX_LP_ALLOCATION_WAD = 0.02 ether;

    IUniswapV2Factory public immutable factory;
    IWETH public immutable weth;
    UniswapV2Locker public immutable locker;

    /// @dev Allow custom allocation of LP tokens other than `LP_TO_LOCK_WAD` (% expressed in WAD)
    uint256 public lpAllocationWad;
    address public lpAllocationRecipient;

    error MaxLPAllocationExceeded();
    error LPRecipientNotEOA();

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
        if (liquidityMigratorData.length > 0) {
            (uint256 lpAllocationWad_, address lpAllocationRecipient_) =
                abi.decode(liquidityMigratorData, (uint256, address));
            // both `lpAllocationWad_` and `lpAllocationRecipient_` can be 0 to indicate no allocation,
            // as long as `lpAllocationWad_` is 0, `lpAllocationRecipient_` is not effective
            require(lpAllocationWad_ <= MAX_LP_ALLOCATION_WAD, MaxLPAllocationExceeded());
            lpAllocationWad = lpAllocationWad_;
            // only allow EOA to receive the lp allocation
            require(lpAllocationRecipient_.code.length == 0, LPRecipientNotEOA());
            lpAllocationRecipient = lpAllocationRecipient_;
        }

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        if (token0 == address(0)) token0 = address(weth);

        address pool = factory.getPair(token0, token1);

        if (pool == address(0)) {
            pool = factory.createPair(token0, token1);
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

        // LP distribution - 5% to locker, (n <= 10)% to allocation recipient, rest to timelock
        liquidity = IUniswapV2Pair(pool).mint(address(this));
        uint256 liquidityToLock = liquidity * LP_TO_LOCK_WAD / WAD;
        uint256 liquidityToTransfer = liquidity - liquidityToLock;
        if (lpAllocationWad > 0) {
            uint256 liquidityToAllocate = liquidity * lpAllocationWad / WAD;
            liquidityToTransfer -= liquidityToAllocate;
            IUniswapV2Pair(pool).transfer(lpAllocationRecipient, liquidityToAllocate);
        }
        IUniswapV2Pair(pool).transfer(recipient, liquidityToTransfer);
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
