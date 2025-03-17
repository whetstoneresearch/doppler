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
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

/// @notice Thrown when the caller is not the Pool contract
error OnlyPool();

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

/// @notice Thrown when the tick range is misordered
error InvalidTickRangeMisordered(int24 tickLower, int24 tickUpper);

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Uniswap V3 pool
 * @custom:security-contact security@whetstone.cc
 */
contract ZoraUniswapV3Migrator is ILiquidityMigrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @notice Address of the Uniswap V3 factory
    IUniswapV3Factory public immutable factory;
    address internal asset;
    address internal numeraire;
    address internal pool;
    uint24 internal fee;

    receive() external payable onlyAirlock {
        // require(msg.sender == airlock, SenderNotAirlock());
    }

    constructor(address airlock_, address factory_) ImmutableAirlock(airlock_) {
        factory = IUniswapV3Factory(factory_);
    }

    function initialize(
        address asset_,
        address numeraire_,
        bytes calldata data
    ) external onlyAirlock returns (address) {
        (uint24 fee_) = abi.decode(data, (uint24));
        asset = asset_;
        numeraire = numeraire_;
        fee = fee_;

        (address token0, address token1) = asset_ < numeraire_ ? (asset_, numeraire_) : (numeraire_, asset_);
        pool = factory.getPool(token0, token1, fee);

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
    ) external payable onlyAirlock returns (uint256 liquidity) {
        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

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

        int24 tickSpacing = factory.feeAmountTickSpacing(fee);

        int24 tickLower = alignTickToTickSpacing(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = alignTickToTickSpacing(TickMath.MAX_TICK, tickSpacing);

        uint128 liquidityAmount = computeLiquidity(sqrtPriceX96, balance0, balance1, tickSpacing);
        mintPosition(tickLower, tickUpper, liquidityAmount);
        return liquidityAmount;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).safeTransferFrom(address(airlock), pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }

    function mintPosition(int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        IUniswapV3Pool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(CallbackData({ asset: asset, numeraire: numeraire, fee: fee }))
        );
    }

    /// @notice Calculates the final LP position that extends from the far tick to the pool's min/max tick
    /// @dev This position ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
    function computeLiquidity(
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        int24 tickSpacing
    ) internal pure returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, amount0, amount1
        );

        int24 posTickLower = alignTickToTickSpacing(TickMath.MIN_TICK, tickSpacing);
        int24 posTickUpper = alignTickToTickSpacing(TickMath.MAX_TICK, tickSpacing);

        require(posTickLower < posTickUpper, InvalidTickRangeMisordered(posTickLower, posTickUpper));

        return liquidity;
    }

    function alignTickToTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (tick < 0) {
            // If the tick is negative, we round up (negatively) the negative result to round down
            return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
        } else {
            // Else if positive, we simply round down
            return tick / tickSpacing * tickSpacing;
        }
    }
}
