// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { DecayMulticurveInitializerHook } from "src/initializers/DecayMulticurveInitializerHook.sol";
import {
    Lock,
    PoolAlreadyInitialized,
    PoolState,
    PoolStatus,
    UniswapV4MulticurveInitializer
} from "src/initializers/UniswapV4MulticurveInitializer.sol";
import { Curve, Multicurve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";

/// @dev Maximum LP fee allowed by this initializer path
uint24 constant MAX_LP_FEE = 100_000;

/// @notice Thrown when configured fee exceeds MAX_LP_FEE
error FeeTooHigh(uint24 fee);

/// @notice Thrown when start fee is below end fee
error InvalidFeeRange(uint24 startFee, uint24 endFee);

/// @notice Thrown when descending schedule duration is zero
error InvalidDurationSeconds(uint64 durationSeconds);

/**
 * @notice Data used to initialize the Decay Multicurve pool
 * @param startFee Dynamic LP fee at schedule start
 * @param fee Dynamic LP fee at schedule end (matches existing v4 initializer naming)
 * @param durationSeconds Number of seconds over which LP fee linearly descends
 * @param tickSpacing Tick spacing for the Uniswap V4 pool
 * @param curves Array of curves to distribute liquidity across
 * @param beneficiaries Array of beneficiaries with their shares
 * @param startingTime Start timestamp for fee decay (swaps are still allowed before start at `startFee`)
 */
struct InitData {
    uint24 startFee;
    uint24 fee;
    uint64 durationSeconds;
    int24 tickSpacing;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    uint32 startingTime;
}

/**
 * @title Decay Multicurve Initializer
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Initializes a Uniswap V4 multicurve pool with timestamp-based linear dynamic LP fee descent.
 */
contract DecayMulticurveInitializer is UniswapV4MulticurveInitializer {
    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     * @param hook_ Address of the Decay Multicurve hook
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
        require(initData.startFee <= MAX_LP_FEE, FeeTooHigh(initData.startFee));
        require(initData.fee <= MAX_LP_FEE, FeeTooHigh(initData.fee));
        require(initData.startFee >= initData.fee, InvalidFeeRange(initData.startFee, initData.fee));

        bool isDescending = initData.startFee > initData.fee;
        if (isDescending) {
            require(initData.durationSeconds > 0, InvalidDurationSeconds(initData.durationSeconds));
        }

        (
            int24 tickSpacing,
            Curve[] memory curves,
            BeneficiaryData[] memory beneficiaries,
            uint256 startingTime,
            uint24 startFee,
            uint24 endFee,
            uint64 durationSeconds
        ) = (
            initData.tickSpacing,
            initData.curves,
            initData.beneficiaries,
            initData.startingTime,
            initData.startFee,
            initData.fee,
            initData.durationSeconds
        );

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: HOOK,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        (Curve[] memory adjustedCurves, int24 tickLower, int24 tickUpper) =
            Multicurve.adjustCurves(curves, 0, tickSpacing, isToken0);

        int24 startTick = isToken0 ? tickLower : tickUpper;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey, sqrtPriceX96);
        DecayMulticurveInitializerHook(address(HOOK))
            .setSchedule(poolKey, startingTime, startFee, endFee, durationSeconds);

        Position[] memory positions =
            Multicurve.calculatePositions(adjustedCurves, tickSpacing, totalTokensOnBondingCurve, 0, isToken0);

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

        // If any dust asset tokens are left in this contract after providing liquidity, send them back to Airlock.
        if (Currency.wrap(asset).balanceOfSelf() > 0) {
            Currency.wrap(asset).transfer(address(airlock), Currency.wrap(asset).balanceOfSelf());
        }

        // Uniswap V4 pools don't have addresses, so return asset to retrieve associated state in `exitLiquidity`.
        return asset;
    }
}
