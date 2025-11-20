// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { FeesManager } from "src/base/FeesManager.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve, adjustCurves, calculatePositions } from "src/libraries/Multicurve.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V4 pool key
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the pool is not locked but collect is called
error PoolNotLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/**
 * @notice Data used to initialize the Uniswap V4 pool
 * @param fee Fee of the Uniswap V4 pool (capped at 1_000_000)
 * @param tickSpacing Tick spacing for the Uniswap V4 pool
 * @param curves Array of curves to distribute liquidity across
 * @param beneficiaries Array of beneficiaries with their shares
 */
struct InitData {
    uint24 fee;
    int24 tickSpacing;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
}

/// @notice Possible status of a pool, note a locked pool cannot be exited
enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Exited
}

/**
 * @notice State of a pool
 * @param numeraire Address of the numeraire currency
 * @param beneficiaries Array of beneficiaries with their shares
 * @param positions Array of positions held in the pool
 * @param status Current status of the pool
 * @param poolKey Key of the Uniswap V4 pool
 * @param farTick The farthest tick that must be reached to allow exiting liquidity
 */
struct PoolState {
    address numeraire;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    PoolStatus status;
    PoolKey poolKey;
    int24 farTick;
}

/**
 * @title Doppler Uniswap V4 Multicurve Initializer
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Initializes a fresh Uniswap V4 pool and distributes liquidity across multiple positions, as
 * described in the Doppler Multicurve whitepaper (https://www.doppler.lol/multicurve.pdf).
 *
 * Liquidity pools can be initialized with two different flows:
 *
 * A. No beneficiaries (possible migration)
 *
 * ┌─────────────┐┌───────────┐      ┌──────┐
 * │Uninitialized││Initialized│      │Exited│
 * └──────┬──────┘└─────┬─────┘      └──┬───┘
 *        │             │               │
 *        │initialize() │               │
 *        │────────────>│               │
 *        │             │               │
 *        │             │exitLiquidity()│
 *        │             │──────────────>│
 * ┌──────┴──────┐┌─────┴─────┐      ┌──┴───┐
 * │Uninitialized││Initialized│      │Exited│
 * └─────────────┘└───────────┘      └──────┘
 *
 *
 * B. With beneficiaries (locked pool, no migration)
 *
 * ┌─────────────┐  ┌──────┐
 * │Uninitialized│  │Locked│
 * └──────┬──────┘  └──┬───┘
 *        │            │
 *        │initialize()│
 *        │───────────>│
 * ┌──────┴──────┐  ┌──┴───┐
 * │Uninitialized│  │Locked│
 * └─────────────┘  └──────┘
 *
 * Passing beneficiaries during the initialization will "lock" the pool, preventing any future migration. However
 * this will allow the collection of fees by the designed beneficiaries. If no beneficiaries are passed, the pool
 * can be migrated later if the conditions are met.
 */
contract UniswapV4MulticurveInitializer is IPoolInitializer, FeesManager, ImmutableAirlock, MiniV4Manager {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Address of the Uniswap V4 Multicurve hook
    IHooks public immutable HOOK;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

    /// @notice Maps a Uniswap V4 poolId to its associated asset
    mapping(PoolId poolId => address asset) internal getAsset;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     * @param hook_ Address of the UniswapV4MulticurveInitializerHook
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks hook_
    ) ImmutableAirlock(airlock_) MiniV4Manager(poolManager_) {
        HOOK = hook_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external virtual onlyAirlock returns (address) {
        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        InitData memory initData = abi.decode(data, (InitData));

        (uint24 fee, int24 tickSpacing, Curve[] memory curves, BeneficiaryData[] memory beneficiaries) =
            (initData.fee, initData.tickSpacing, initData.curves, initData.beneficiaries);

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

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(address asset)
        external
        onlyAirlock
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Initialized, PoolAlreadyExited());
        getState[asset].status = PoolStatus.Exited;

        token0 = Currency.unwrap(state.poolKey.currency0);
        token1 = Currency.unwrap(state.poolKey.currency1);

        (, int24 tick,,) = poolManager.getSlot0(state.poolKey.toId());
        int24 farTick = state.farTick;
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, state.positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /**
     * @notice Returns the positions currently held in the Uniswap V4 pool for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return Array of positions currently held in the Uniswap V4 pool
     */
    function getPositions(address asset) external view returns (Position[] memory) {
        return getState[asset].positions;
    }

    /**
     * @notice Returns the beneficiaries and their shares for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return Array of beneficiaries with their shares
     */
    function getBeneficiaries(address asset) external view returns (BeneficiaryData[] memory) {
        return getState[asset].beneficiaries;
    }

    /// @inheritdoc FeesManager
    function _collectFees(PoolId poolId) internal override returns (BalanceDelta fees) {
        PoolState memory state = getState[getAsset[poolId]];
        require(state.status == PoolStatus.Locked, PoolNotLocked());
        fees = _collect(state.poolKey, state.positions);
    }
}
