// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

contract UniswapV4Migrator is ILiquidityMigrator, ImmutableAirlock {
    using StateLibrary for IPoolManager;

    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    PositionManager public immutable positionManager;

    mapping(address token0 => mapping(address token1 => PoolKey poolKey)) public getPoolKeyForPair;

    receive() external payable { }

    constructor(address airlock_, address poolManager_, address payable positionManager_) ImmutableAirlock(airlock_) {
        poolManager = IPoolManager(poolManager_);
        positionManager = PositionManager(positionManager_);
    }

    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        (uint24 fee, int24 tickSpacing) = abi.decode(liquidityMigratorData, (uint24, int24));

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(address(0)),
            fee: fee,
            tickSpacing: tickSpacing
        });

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 != 0) {
            IPoolManager(poolManager).initialize(poolKey, TickMath.MIN_SQRT_PRICE);
        }

        getPoolKeyForPair[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] = poolKey;

        return address(0);
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        uint256 balance0;
        bytes memory actions;
        bytes[] memory params;

        if (token0 == address(0)) {
            params = new bytes[](3);
            params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, recipient);
            balance0 = address(this).balance;
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        } else {
            params = new bytes[](2);
            balance0 = ERC20(token0).balanceOf(address(this));
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        }

        PoolKey memory poolKey = getPoolKeyForPair[token0][token1];

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            uint128(balance0),
            uint128(balance1)
        );

        params[0] = abi.encode(
            getPoolKeyForPair[token0][token1],
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            liquidity,
            uint128(balance0),
            uint128(balance1),
            recipient,
            new bytes(0)
        );

        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        positionManager.modifyLiquidities{ value: token0 == address(0) ? balance0 : 0 }(
            abi.encode(actions, params), block.timestamp
        );
    }
}
