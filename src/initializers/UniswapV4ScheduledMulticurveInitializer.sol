// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import {
    Lock,
    PoolAlreadyInitialized,
    PoolState,
    PoolStatus,
    UniswapV4MulticurveInitializer
} from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4ScheduledMulticurveInitializerHook } from "src/UniswapV4ScheduledMulticurveInitializerHook.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { Curve, adjustCurves, calculatePositions } from "src/libraries/Multicurve.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";

/**
 * @notice Data used to initialize the Uniswap V4 pool
 * @param fee Fee of the Uniswap V4 pool (capped at 1_000_000)
 * @param tickSpacing Tick spacing for the Uniswap V4 pool
 * @param curves Array of curves to distribute liquidity across
 * @param beneficiaries Array of beneficiaries with their shares
 * @param startingTime Start of the sale as a unix timestamp
 */
struct InitData {
    uint24 fee;
    int24 tickSpacing;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    uint32 startingTime;
}

contract UniswapV4ScheduledMulticurveInitializer is UniswapV4MulticurveInitializer {
    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     * @param hook_ Address of the UniswapV4MulticurveInitializerHook
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks hook_
    ) UniswapV4MulticurveInitializer(airlock_, poolManager_, hook_) { }

    /// @inheritdoc UniswapV4MulticurveInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external override onlyAirlock returns (address) {
        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        InitData memory initData = abi.decode(data, (InitData));

        (
            uint24 fee,
            int24 tickSpacing,
            Curve[] memory curves,
            BeneficiaryData[] memory beneficiaries,
            uint32 startingTime
        ) = (initData.fee, initData.tickSpacing, initData.curves, initData.beneficiaries, initData.startingTime);

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: HOOK,
            fee: fee,
            tickSpacing: tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        (Curve[] memory adjustedCurves, int24 tickLower, int24 tickUpper) =
            adjustCurves(curves, 0, tickSpacing, isToken0);

        int24 startTick = isToken0 ? tickLower : tickUpper;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey, sqrtPriceX96);
        UniswapV4ScheduledMulticurveInitializerHook(address(HOOK)).setStartingTime(poolKey, startingTime);

        Position[] memory positions =
            calculatePositions(adjustedCurves, tickSpacing, totalTokensOnBondingCurve, 0, isToken0);

        PoolState memory state = PoolState({
            numeraire: numeraire,
            beneficiaries: beneficiaries,
            positions: positions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey,
            farTick: isToken0 ? tickUpper : tickLower
        });

        getState[asset] = state;
        getAsset[poolKey.toId()] = asset;

        SafeTransferLib.safeTransferFrom(asset, address(airlock), address(this), totalTokensOnBondingCurve);
        _mint(poolKey, positions);

        emit Create(address(poolManager), asset, numeraire);

        if (beneficiaries.length != 0) {
            _storeBeneficiaries(poolKey, beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES);
            emit Lock(asset, beneficiaries);
        }

        // If any dust asset tokens are left in this contract after providing liquidity, we send them
        // back to the Airlock so they'll be transferred to the associated governance or burnt
        if (Currency.wrap(asset).balanceOfSelf() > 0) {
            Currency.wrap(asset).transfer(address(airlock), Currency.wrap(asset).balanceOfSelf());
        }

        // Uniswap V4 pools don't have addresses, so we are returning the asset address
        // instead to retrieve the associated state later during the `exitLiquidity` call
        return asset;
    }
}
