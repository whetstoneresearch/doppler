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
import { INonfungiblePositionManager } from "@zora-protocol/coins/src/interfaces/INonfungiblePositionManager.sol";

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

    INonfungiblePositionManager public nonfungiblePositionManager;
    uint256 public lpTokenId;
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
        (uint24 fee_, address nonfungiblePositionManager_) = abi.decode(data, (uint24, address));
        asset = asset_;
        numeraire = numeraire_;
        fee = fee_;
        nonfungiblePositionManager = INonfungiblePositionManager(nonfungiblePositionManager_);
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
        uint160,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }
        // TODO: use min/max tick and round based on tickspacing
        int24 tickLower = -887_200;
        int24 tickUpper = 887_200;

        ERC20(token0).approve(address(nonfungiblePositionManager), balance0);
        ERC20(token1).approve(address(nonfungiblePositionManager), balance1);

        // uint128 liquidityAmount = computeLiquidity(sqrtPriceX96, balance0, balance1, tickSpacing);
        // mintPosition(tickLower, tickUpper, liquidityAmount);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: balance0,
            amount1Desired: balance1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(asset),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint128 liquidityAmount,,) =
            INonfungiblePositionManager(nonfungiblePositionManager).mint(params);

        lpTokenId = tokenId;

        return liquidityAmount;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        require(msg.sender == pool, OnlyPool());

        address token0 = callbackData.asset < callbackData.numeraire ? callbackData.asset : callbackData.numeraire;
        address token1 = callbackData.asset < callbackData.numeraire ? callbackData.numeraire : callbackData.asset;

        ERC20(token0).safeTransfer(pool, amount0Owed);
        ERC20(token1).safeTransfer(pool, amount1Owed);
    }

    function alignTickToTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }
}
