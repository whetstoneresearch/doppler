// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
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
import { calculatePositions, adjustCurves, Curve } from "src/libraries/Multicurve.sol";
import { DookMulticurveHook } from "src/DookMulticurveHook.sol";
import { IDook } from "src/interfaces/IDook.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG, ON_GRADUATION_FLAG } from "src/base/BaseDook.sol";

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V4 pool key
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/**
 * @notice Emitted when the state of a Doppler Hook is set
 * @param dook Address of the Doppler Hook
 * @param flag Flag of the Doppler Hook (see flags in BaseDook.sol)
 */
event SetDookState(address indexed dook, uint256 indexed flag);

/// @notice Emitted when a dook is linked to a pool
event SetDook(address indexed asset, address indexed dook);

/// @notice Emitted when a pool graduates
event Graduate(address indexed asset);

/**
 * @notice Thrown when the pool is not in the expected status
 * @param expected Expected pool status
 * @param actual Actual pool status
 */
error WrongPoolStatus(PoolStatus expected, PoolStatus actual);

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/// @notice Thrown when the hook is not provided but migration is attempted
error CannotMigratePoolNoProvidedDook();

/// @notice Thrown when an unauthorized sender calls `setDookState()`
error SenderNotAirlockOwner();

/// @notice Thrown when an unauthorized sender tries to associate a Doppler Hook to a pool
error SenderNotAuthorized();

/// @notice Thrown when the given Doppler Hook is not enabled
error DookNotEnabled();

/// @notice Thrown when the lengths of two arrays do not match
error ArrayLengthsMismatch();

/// @notice Thrown when the far tick is unreachable
error UnreachableFarTick();

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
    int24 farTick;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    address dook;
    bytes onInitializationDookCalldata;
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
    Curve[] adjustedCurves;
    uint256 totalTokensOnBondingCurve;
    address dook;
    bytes graduationDookCalldata;
    PoolStatus status;
    PoolKey poolKey;
    int24 farTick;
}

/**
 * @title Doppler Hook (Dook) Uniswap V4 Multicurve Initializer
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
contract DookMulticurveInitializer is IPoolInitializer, FeesManager, ImmutableAirlock, MiniV4Manager {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Address of the DookMulticurveHook contract
    IHooks public immutable HOOK;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

    /// @notice Maps a Uniswap V4 poolId to its associated asset
    mapping(PoolId poolId => address asset) internal getAsset;

    /// @notice Returns a non-zero value if a Doppler hook is enabled
    mapping(address dook => uint256 flags) public isDookEnabled;

    /// @notice Returns the delegated authority for a user
    mapping(address user => address authority) public getAuthority;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     * @param hook_ Address of the DookMulticurveHook contract
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
        require(
            getState[asset].status == PoolStatus.Uninitialized,
            WrongPoolStatus(PoolStatus.Uninitialized, getState[asset].status)
        );

        InitData memory initData = abi.decode(data, (InitData));
        (PoolKey memory poolKey, Position[] memory positions) =
            _initialize(asset, numeraire, totalTokensOnBondingCurve, initData);

        PoolId poolId = poolKey.toId();
        getAsset[poolId] = asset;

        uint256 dookFlag = isDookEnabled[initData.dook];

        if (initData.dook != address(0)) {
            require(dookFlag > 0, DookNotEnabled());
            DookMulticurveHook(address(HOOK)).setDook(poolId, initData.dook);
            DookMulticurveHook(address(HOOK)).updateDynamicLPFee(poolKey, initData.fee);
        }

        if (dookFlag & ON_INITIALIZATION_FLAG != 0) {
            IDook(initData.dook).onInitialization(asset, initData.onInitializationDookCalldata);
        }

        SafeTransferLib.safeTransferFrom(asset, address(airlock), address(this), totalTokensOnBondingCurve);
        _mint(poolKey, positions);

        emit Create(address(poolManager), asset, numeraire);

        if (initData.beneficiaries.length != 0) {
            _storeBeneficiaries(poolKey, initData.beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES);
            emit Lock(asset, initData.beneficiaries);
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

    /// @dev Internal function to avoid stack too deep errors
    function _initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        InitData memory initData
    ) private returns (PoolKey memory poolKey, Position[] memory positions) {
        (Curve[] memory curves, int24 farTick, address dook) = (initData.curves, initData.farTick, initData.dook);

        poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: HOOK,
            fee: initData.dook != address(0) ? LPFeeLibrary.DYNAMIC_FEE_FLAG : initData.fee,
            tickSpacing: initData.tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        (Curve[] memory adjustedCurves, int24 lowerTickBoundary, int24 upperTickBoundary) =
            adjustCurves(curves, 0, initData.tickSpacing, isToken0);

        int24 startTick;

        if (isToken0) {
            startTick = lowerTickBoundary;
            require(farTick > startTick && farTick <= upperTickBoundary, UnreachableFarTick());
        } else {
            startTick = upperTickBoundary;
            farTick = -farTick;
            require(farTick < startTick && farTick >= lowerTickBoundary, UnreachableFarTick());
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey, sqrtPriceX96);

        positions = calculatePositions(adjustedCurves, initData.tickSpacing, totalTokensOnBondingCurve, 0, isToken0);

        PoolState memory state = PoolState({
            numeraire: numeraire,
            beneficiaries: initData.beneficiaries,
            adjustedCurves: adjustedCurves,
            totalTokensOnBondingCurve: totalTokensOnBondingCurve,
            dook: dook,
            graduationDookCalldata: initData.graduationDookCalldata,
            status: initData.beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey,
            farTick: farTick
        });

        getState[asset] = state;
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
        require(state.status == PoolStatus.Initialized, WrongPoolStatus(PoolStatus.Initialized, state.status));
        getState[asset].status = PoolStatus.Exited;

        token0 = Currency.unwrap(state.poolKey.currency0);
        token1 = Currency.unwrap(state.poolKey.currency1);

        _canGraduateOrMigrate(state.poolKey.toId(), asset == token0, state.farTick);
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(state.farTick);

        Position[] memory positions = calculatePositions(
            state.adjustedCurves, state.poolKey.tickSpacing, state.totalTokensOnBondingCurve, 0, asset == token0
        );
        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /**
     * @notice Delegates `msg.sender`'s pool authority to another address
     * @param delegatedAuthority Address to delgate to
     */
    function delegateAuthority(address delegatedAuthority) external {
        getAuthority[msg.sender] = delegatedAuthority;
    }

    /**
     * @notice Sets the Doppler hook for a given asset's pool
     * @param asset Address to migrate
     */
    function setDook(
        address asset,
        address dook,
        bytes calldata onInitializationCalldata,
        bytes calldata onGraduationCalldata
    ) external {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, WrongPoolStatus(PoolStatus.Locked, state.status));

        (, address timelock,,,,,,,,) = airlock.getAssetData(asset);
        address authority = getAuthority[timelock];
        require(msg.sender == authority || msg.sender == timelock, SenderNotAuthorized());

        if (dook != address(0)) require(isDookEnabled[dook] > 0, DookNotEnabled());

        getState[asset].dook = dook;
        getState[asset].graduationDookCalldata = onGraduationCalldata;
        emit SetDook(asset, dook);

        DookMulticurveHook(address(HOOK)).setDook(state.poolKey.toId(), dook);
        IDook(dook).onInitialization(asset, onInitializationCalldata);
    }

    /**
     * @notice Graduates a pool if the conditions are met, this is a one-way operation
     * @param asset Address of the asset to graduate
     */
    function graduate(address asset) external {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, WrongPoolStatus(PoolStatus.Locked, state.status));

        address dook = state.dook;
        uint256 flags = isDookEnabled[dook];
        if (dook == address(0) || flags & ON_GRADUATION_FLAG == 0) revert CannotMigratePoolNoProvidedDook();

        _canGraduateOrMigrate(state.poolKey.toId(), asset == Currency.unwrap(state.poolKey.currency0), state.farTick);

        getState[asset].status = PoolStatus.Graduated;
        emit Graduate(asset);
        IDook(dook).onGraduation(asset, state.graduationDookCalldata);
    }

    /**
     * @notice Updates the LP fee for a given asset's pool
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @param lpFee New dynamic LP fee to set
     */
    function updateDynamicLPFee(address asset, uint24 lpFee) external {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, WrongPoolStatus(PoolStatus.Locked, state.status));
        require(msg.sender == state.dook, SenderNotAuthorized());
        DookMulticurveHook(address(HOOK)).updateDynamicLPFee(getState[asset].poolKey, lpFee);
    }

    /**
     * @notice Sets the state of a given Doppler hooks array
     * @param dooks Array of Doppler hook addresses
     * @param flags Array of flags to set (see flags in BaseDook.sol)
     */
    function setDookState(address[] calldata dooks, uint256[] calldata flags) external {
        require(msg.sender == airlock.owner(), SenderNotAirlockOwner());

        uint256 length = dooks.length;

        if (length != flags.length) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i != length; ++i) {
            isDookEnabled[dooks[i]] = flags[i];
            emit SetDookState(dooks[i], flags[i]);
        }
    }

    /**
     * @notice Returns the positions currently held in the Uniswap V4 pool for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return Array of positions currently held in the Uniswap V4 pool
     */
    function getPositions(address asset) public view returns (Position[] memory) {
        PoolState memory state = getState[asset];
        address token0 = Currency.unwrap(state.poolKey.currency0);
        Position[] memory positions = calculatePositions(
            state.adjustedCurves, state.poolKey.tickSpacing, state.totalTokensOnBondingCurve, 0, asset == token0
        );
        return positions;
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
        address asset = getAsset[poolId];
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Locked, WrongPoolStatus(PoolStatus.Locked, state.status));
        fees = _collect(state.poolKey, getPositions(asset));
    }

    /**
     * @notice Returns true if a pool can be graduated or migrated
     * @param poolId PoolId of the Uniswap V4 pool
     * @param isToken0 True if the asset is token0 in the pool
     * @param farTick The farthest tick that must be reached to allow exiting liquidity
     */
    function _canGraduateOrMigrate(PoolId poolId, bool isToken0, int24 farTick) internal view {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        require(isToken0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));
    }
}
