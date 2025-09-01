// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";

import { EMPTY_ADDRESS } from "src/types/Constants.sol";
import { FeesManager } from "src/base/FeesManager.sol";
import { Position } from "src/types/Position.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { Airlock } from "src/Airlock.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { calculatePositions, validateCurves } from "src/libraries/Multicurve.sol";

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

/// @notice Thrown when the pool is locked but collect is called
error PoolLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

struct InitData {
    uint24 fee;
    int24 tickSpacing;
    int24[] tickLower;
    int24[] tickUpper;
    uint16[] numPositions;
    uint256[] shareToBeSold;
    BeneficiaryData[] beneficiaries;
}

enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Exited
}

struct PoolState {
    address numeraire;
    int24[] tickLower;
    int24[] tickUpper;
    uint256[] shareToBeSold;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    PoolStatus status;
    PoolKey poolKey;
}

/**
 * @title Doppler Uniswap V4 Multicurve Initializer
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Initializes a fresh Uniswap V4 pool and distributes liquidity across multiple positions, as
 * described in the Doppler Multicurve whitepaper (https://www.doppler.lol/multicurve.pdf)
 */
contract UniswapV4MulticurveInitializer is IPoolInitializer, FeesManager, ImmutableAirlock, MiniV4Manager {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Address of the Uniswap V4 Multicurve hook
    IHooks public immutable hook;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

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
        hook = hook_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external onlyAirlock returns (address pool) {
        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        InitData memory initData = abi.decode(data, (InitData));

        (
            uint24 fee,
            int24 tickSpacing,
            int24[] memory tickLower,
            int24[] memory tickUpper,
            uint16[] memory numPositions,
            uint256[] memory shareToBeSold,
            BeneficiaryData[] memory beneficiaries
        ) = (
            initData.fee,
            initData.tickSpacing,
            initData.tickLower,
            initData.tickUpper,
            initData.numPositions,
            initData.shareToBeSold,
            initData.beneficiaries
        );

        int24 startTick =
            validateCurves(asset, numeraire, tickSpacing, tickLower, tickUpper, numPositions, shareToBeSold);

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: hook,
            fee: fee,
            tickSpacing: tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey, sqrtPriceX96);

        Position[] memory positions = calculatePositions(
            poolKey, isToken0, numPositions, tickLower, tickUpper, shareToBeSold, totalTokensOnBondingCurve
        );

        PoolState memory state = PoolState({
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            shareToBeSold: shareToBeSold,
            beneficiaries: beneficiaries,
            positions: positions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey
        });

        getState[asset] = state;

        _mint(poolKey, positions);

        emit Create(address(poolManager), asset, numeraire);

        if (beneficiaries.length != 0) {
            _storeBeneficiaries(poolKey.toId(), airlock.owner(), beneficiaries);
            getPoolKey[poolKey.toId()] = poolKey;
            emit Lock(pool, beneficiaries);
        }

        return EMPTY_ADDRESS;
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address asset
    )
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

        int24 tick;
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(state.poolKey.toId());
        bool isToken0 = asset == token0;

        int24 farTick = isToken0 ? state.tickUpper[state.tickUpper.length - 1] : state.tickLower[0];
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, state.positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /// @inheritdoc FeesManager
    function _collectFees(
        PoolId poolId
    ) internal override returns (BalanceDelta fees) {
        // TODO: Fix this.
        address asset;
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, PoolLocked());

        return _collect(state.poolKey, state.positions);
    }

    /**
     * @notice Returns the positions currently held in the Uniswap V4 pool for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return positions Array of positions currently held in the Uniswap V4 pool
     */
    function getPositions(
        address asset
    ) external view returns (Position[] memory) {
        return getState[asset].positions;
    }
}
