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
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { FeesManager } from "src/base/FeesManager.sol";
import { Position } from "src/types/Position.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { calculatePositions, adjustCurves, Curve } from "src/libraries/MulticurveLibV2.sol";
import { UniswapV4HookedMulticurveInitializerHook } from "src/HookedMulticurveInitializerHook.sol";
import { IDook } from "src/interfaces/IDook.sol";

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V4 pool key
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/**
 * @notice Emitted when the state of a hook is set
 * @param hook Address of the hook
 * @param state State of the module
 */
event SetHookState(address indexed hook, bool indexed state);

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the pool is not locked but collect is called
error PoolNotLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/// @notice Thrown when the hook is not provided but migration is attempted
error CannotMigratePoolNoProvidedHook();

/// @notice Thrown when a non-authorized owner tries to enable new hook modules
error HookModuleNotAuthorized(address owner, address caller);

/// @notice Thrown when a non-authorized owner tries to enable new hook modules
error HookMigrationNotAuthorized(address delegate, address caller);

/// @notice Thrown when the hook state is not the expected one
error WrongHookState(address module, bool expected, bool actual);

/// @notice Thrown when the lengths of two arrays do not match
error ArrayLengthsMismatch();

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
    address dook;
    bytes graduationDookCalldata;
}

/// @notice Possible status of a pool, note a locked pool cannot be exited
enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Graduated,
    Exited
}

/**
 * @notice State of a pool
 * @param numeraire Address of the numeraire currency
 * @param beneficiaries Array of beneficiaries with their shares
 * @param positions Array of positions held in the pool
 * @param dook Address of the Doppler hook
 * @param status Current status of the pool
 * @param poolKey Key of the Uniswap V4 pool
 * @param farTick The farthest tick that must be reached to allow exiting liquidity
 */
struct PoolState {
    address numeraire;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    address dook;
    bytes graduationDookCalldata;
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
contract HookedMulticurveInitializer is IPoolInitializer, FeesManager, ImmutableAirlock, MiniV4Manager {
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

    /// @notice Returns the state of a given hook module
    mapping(address module => bool state) public isDookEnabled;

    /// @notice Delegated authority
    mapping(address user => address delegation) public getAuthority;

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
    ) external override onlyAirlock returns (address) {
        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        InitData memory initData = abi.decode(data, (InitData));

        (
            uint24 fee,
            int24 tickSpacing,
            Curve[] memory curves,
            BeneficiaryData[] memory beneficiaries,
            address dook,
            bytes memory graduationDookCalldata
        ) = (
            initData.fee,
            initData.tickSpacing,
            initData.curves,
            initData.beneficiaries,
            initData.dook,
            initData.graduationDookCalldata
        );

        _validateModuleState(dook, true);

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: HOOK,
            fee: fee,
            tickSpacing: tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        (Curve[] memory adjustedCurves, int24 tickLower, int24 tickUpper,) =
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
            dook: dook,
            graduationDookCalldata: graduationDookCalldata,
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

        _canGraduateOrMigrate(state.poolKey.toId(), asset == token0, state.farTick);
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(state.farTick);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, state.positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /**
     * @notice Delegates hook migration approval authority to another address
     * @param delegatedAuthority Address to delgate to
     */
    function delegateAuthority(address delegatedAuthority) external {
        getAuthority[msg.sender] = delegatedAuthority;
    }

    /**
     * @notice Sets the Doppler hook for a given asset's pool if not already set
     * @param asset Address to migrate
     */
    function setDook(address asset, address dook, bytes calldata data) external {
        PoolState memory state = getState[asset];

        // Cannot push if can internal or external migrate
        require(state.status == PoolStatus.Locked, PoolAlreadyExited());
        (, address timelock,,,,,,,,) = airlock.getAssetData(asset);

        _validateModuleState(dook, true);
        require(state.dook == address(0), "DookAlreadySet");

        address delegate = getAuthority[timelock];

        require((msg.sender == delegate) || (msg.sender == timelock), HookMigrationNotAuthorized(delegate, msg.sender));

        getState[asset].dook = dook;
        IDook(dook).onInitialization(asset, data);
    }

    /**
     * @notice Triggers a pre-specified graduation hook if conditions are met
     * @notice This is one way and cannot be done again
     * @param asset Address to migrate
     */
    function graduate(address asset) external {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Initialized, PoolAlreadyExited());

        _canGraduateOrMigrate(state.poolKey.toId(), asset == Currency.unwrap(state.poolKey.currency0), state.farTick);

        address dook = state.dook;
        if (address(dook) == address(0)) {
            revert CannotMigratePoolNoProvidedHook();
        }

        getState[asset].status = PoolStatus.Graduated;
        IDook(dook).onGraduation(asset, state.graduationDookCalldata);
    }

    function _canGraduateOrMigrate(PoolId poolId, bool isToken0, int24 farTick) internal view {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        require(
            isToken0 ? currentTick >= farTick : currentTick <= farTick,
            CannotMigrateInsufficientTick(farTick, currentTick)
        );
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

    /**
     * @notice Sets the state of the given Doppler hooks
     * @param dooks Array of Doppler hook addresses
     * @param states Array of module states
     */
    function setHookState(address[] calldata dooks, bool[] calldata states) external {
        address owner = airlock.owner();
        require(msg.sender == owner, HookModuleNotAuthorized(owner, msg.sender));

        uint256 length = dooks.length;

        if (length != states.length) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i != length; ++i) {
            isDookEnabled[dooks[i]] = states[i];
            emit SetHookState(dooks[i], states[i]);
        }
    }

    /**
     * @dev Validates the state of a hook
     * @param hook Address of the hook
     * @param state Expected state of the hook
     */
    function _validateModuleState(address hook, bool state) internal view {
        if (hook != address(0)) {
            require(isDookEnabled[address(hook)] == state, WrongHookState(hook, state, isDookEnabled[hook]));
        }
    }
}
