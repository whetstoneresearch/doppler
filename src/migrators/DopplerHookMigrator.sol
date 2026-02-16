// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import {
    ON_GRADUATION_FLAG,
    ON_INITIALIZATION_FLAG,
    ON_SWAP_FLAG,
    REQUIRES_DYNAMIC_LP_FEE_FLAG
} from "src/base/BaseDopplerHook.sol";
import { BaseHook } from "src/base/BaseHook.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ProceedsSplitter, SplitConfiguration } from "src/base/ProceedsSplitter.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES, storeBeneficiaries } from "src/types/BeneficiaryData.sol";
import { EMPTY_ADDRESS } from "src/types/Constants.sol";
import { Position } from "src/types/Position.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when computed liquidity is zero
error ZeroLiquidity();

/// @notice Thrown when the tick is out of range for the pool
error TickOutOfRange();

/// @notice Thrown when an unauthorized sender calls `setDopplerHookState()`
error SenderNotAirlockOwner();

/// @notice Thrown when an unauthorized sender tries to associate a Doppler Hook to a pool
error SenderNotAuthorized();

/// @notice Thrown when the lengths of two arrays do not match
error ArrayLengthsMismatch();

/**
 * @notice Thrown when the pool is not in the expected status
 * @param expected Expected pool status
 * @param actual Actual pool status
 */
error WrongPoolStatus(uint8 expected, uint8 actual);

/// @notice Thrown when the given Doppler Hook is not enabled
error DopplerHookNotEnabled();

/// @notice Thrown when a hook requires dynamic LP fee but the pool is fixed-fee
error HookRequiresDynamicLPFee();

/// @notice Thrown when a pool does not use dynamic fees
error PoolNotDynamicFee();

/// @notice Thrown when the provided LP fee is above the maximum allowed
error LPFeeTooHigh(uint24 maxFee, uint256 fee);

/// @notice Thrown when the migrator is not the initializer
error OnlySelf();

/**
 * @notice Emitted when an asset is migrated
 * @param asset Address of the asset token
 * @param poolKey Pool receiving the migrated liquidity
 */
event Migrate(address indexed asset, PoolKey poolKey);

/**
 * @notice Emitted when the state of a Doppler Hook is set
 * @param dopplerHook Address of the Doppler Hook
 * @param flag Flag of the Doppler Hook (see flags in BaseDopplerHook.sol)
 */
event SetDopplerHookState(address indexed dopplerHook, uint256 indexed flag);

/// @notice Emitted when a dopplerHook is linked to a pool
event SetDopplerHook(address indexed asset, address indexed dopplerHook);

/**
 * @notice Emitted when a Swap occurs
 * @param sender Address calling the PoolManager
 * @param poolKey Key of the related pool
 * @param poolId Id of the related pool
 * @param params Parameters of the swap
 * @param amount0 Balance denominated in token0
 * @param amount1 Balance denominated in token1
 * @param hookData Data passed to the hook
 */
event Swap(
    address indexed sender,
    PoolKey indexed poolKey,
    PoolId indexed poolId,
    IPoolManager.SwapParams params,
    int128 amount0,
    int128 amount1,
    bytes hookData
);

/**
 * @notice Emitted when a user delegates their pool authority to another address
 * @param user Address of the user delegating their authority
 * @param authority Address of the delegated authority
 */
event DelegateAuthority(address indexed user, address indexed authority);

/// @notice Possible status of a pool
enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked
}

/**
 * @notice Data to use for the migration
 * @param isToken0 True if the currency0 is the asset we're selling
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 * @param useDynamicFee True if the pool uses dynamic fees
 * @param feeOrInitialDynamicFee Fee of the pool (fixed fee) or initial dynamic fee
 * @param dopplerHook Address of the optional Doppler hook
 * @param onInitializationCalldata Calldata passed to the Doppler hook on initialization
 * @param onGraduationCalldata Calldata passed to the Doppler hook on graduation
 */
struct AssetData {
    bool isToken0;
    PoolKey poolKey;
    uint32 lockDuration;
    uint24 feeOrInitialDynamicFee;
    BeneficiaryData[] beneficiaries;
    bool useDynamicFee;
    address dopplerHook;
    bytes onInitializationCalldata;
    PoolStatus status;
}

struct Pair {
    address token0;
    address token1;
}

/// @dev Maximum LP fee allowed for dynamic fee updates (15%)
uint24 constant MAX_LP_FEE = 150_000;

/**
 * @title Doppler Hook Migrator
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Migrates liquidity into a fresh Uniswap V4 pool using a migrator hook for initialization,
 * and distributes liquidity across multiple positions.
 */
contract DopplerHookMigrator is ILiquidityMigrator, ImmutableAirlock, BaseHook, ProceedsSplitter {
    using CurrencyLibrary for Currency;

    /// @notice Address of the StreamableFeesLockerV2 contract
    StreamableFeesLockerV2 public immutable locker;

    /// @notice Mapping of asset pairs to their respective asset data
    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    /// @notice Maps a Uniswap V4 poolId to its associated asset
    mapping(PoolId poolId => address asset) public getAsset;

    mapping(address asset => Pair) public getPair;

    /// @notice Returns a non-zero value if a Doppler hook is enabled
    mapping(address dopplerHook => uint256 flags) public isDopplerHookEnabled;

    /// @notice Returns the delegated authority for a user
    mapping(address user => address authority) public getAuthority;

    /// @notice Fallback function to receive ETH
    receive() external payable { }

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of Uniswap V4 PoolManager contract
     * @param locker_ Address of the StreamableFeesLockerV2 contract (must be approved)
     * @param topUpDistributor Address of the TopUpDistributor contract
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        StreamableFeesLockerV2 locker_,
        TopUpDistributor topUpDistributor
    ) ImmutableAirlock(airlock_) ImmutableState(poolManager_) ProceedsSplitter(topUpDistributor) {
        locker = locker_;
    }

    /// @inheritdoc ILiquidityMigrator
    function initialize(address asset, address numeraire, bytes calldata data) external onlyAirlock returns (address) {
        (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,, // onGraduationCalldata (unused)
            address proceedsRecipient,
            uint256 proceedsShare
        ) = abi.decode(data, (uint24, int24, uint32, BeneficiaryData[], bool, address, bytes, bytes, address, uint256));

        isTickSpacingValid(tickSpacing);
        require(feeOrInitialDynamicFee <= MAX_LP_FEE, LPFeeTooHigh(MAX_LP_FEE, feeOrInitialDynamicFee));

        // Validate beneficiaries without storing them (locker will store on migrate).
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES, _storeBeneficiary
        );

        address currency0 = asset < numeraire ? asset : numeraire;
        address currency1 = asset < numeraire ? numeraire : asset;

        {
            uint256 flags = isDopplerHookEnabled[dopplerHook];
            if (dopplerHook != address(0)) {
                require(flags != 0, DopplerHookNotEnabled());
                require(flags & REQUIRES_DYNAMIC_LP_FEE_FLAG == 0 || useDynamicFee, HookRequiresDynamicLPFee());
            }

            PoolStatus status = getAssetData[currency0][currency1].status;
            require(status == PoolStatus.Uninitialized, WrongPoolStatus(uint8(PoolStatus.Uninitialized), uint8(status)));
        }

        getAssetData[currency0][currency1] = AssetData({
            isToken0: currency0 == asset,
            poolKey: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                hooks: IHooks(address(this)),
                fee: useDynamicFee ? LPFeeLibrary.DYNAMIC_FEE_FLAG : feeOrInitialDynamicFee,
                tickSpacing: tickSpacing
            }),
            lockDuration: lockDuration,
            beneficiaries: beneficiaries,
            feeOrInitialDynamicFee: feeOrInitialDynamicFee,
            useDynamicFee: useDynamicFee,
            dopplerHook: dopplerHook,
            onInitializationCalldata: onInitializationCalldata,
            status: PoolStatus.Initialized
        });

        if (proceedsShare > 0) {
            _setSplit(
                currency0,
                currency1,
                SplitConfiguration({ recipient: proceedsRecipient, isToken0: asset < numeraire, share: proceedsShare })
            );
        }

        // Uniswap V4 pools are represented by their PoolKey, so we return an empty address instead
        return EMPTY_ADDRESS;
    }

    /// @inheritdoc ILiquidityMigrator
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256) {
        AssetData memory data = getAssetData[token0][token1];
        (bool isToken0, int24 tickSpacing) = (data.isToken0, data.poolKey.tickSpacing);

        address asset = isToken0 ? token0 : token1;
        address numeraire = isToken0 ? token1 : token0;
        getPair[asset] = Pair(token0, token1);
        PoolStatus status = getAssetData[token0][token1].status;
        require(status != PoolStatus.Uninitialized, WrongPoolStatus(uint8(PoolStatus.Uninitialized), uint8(status)));
        getAssetData[token0][token1].status = PoolStatus.Locked;

        // Re-check allowlist here because governance can update it between initialize() and migrate().
        uint256 flags = isDopplerHookEnabled[data.dopplerHook];
        if (data.dopplerHook != address(0)) {
            require(flags != 0, DopplerHookNotEnabled());
            require(flags & REQUIRES_DYNAMIC_LP_FEE_FLAG == 0 || data.useDynamicFee, HookRequiresDynamicLPFee());
        }

        int24 currentTick = poolManager.initialize(data.poolKey, sqrtPriceX96);

        if (data.useDynamicFee) {
            poolManager.updateDynamicLPFee(data.poolKey, data.feeOrInitialDynamicFee);
        }

        if (data.dopplerHook != address(0) && flags & ON_INITIALIZATION_FLAG != 0) {
            IDopplerHook(data.dopplerHook).onInitialization(asset, data.poolKey, data.onInitializationCalldata);
        }

        uint256 balance0 = data.poolKey.currency0.balanceOfSelf();
        uint256 balance1 = data.poolKey.currency1.balanceOfSelf();

        if (splitConfigurationOf[token0][token1].share > 0) {
            (balance0, balance1) = _distributeSplit(token0, token1, balance0, balance1);
        }

        int24 lowerTick = TickMath.minUsableTick(tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(tickSpacing);

        // Align current tick with tick spacing
        currentTick = currentTick / tickSpacing * tickSpacing;

        if (currentTick < lowerTick || currentTick > upperTick) revert TickOutOfRange();

        // We're adding liquidity to two single-sided positions instead of a full range position, this is to ensure
        // we're using as much tokens as possible and will result in more liquidity being added to the pool. Note that
        // we decremented the balances by `1` (if possible) to avoid rounding issues during liquidity computation
        uint128 belowPriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(currentTick - tickSpacing),
            0,
            balance1 == 0 ? 0 : uint128(balance1) - 1
        );

        uint128 abovePriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(currentTick + tickSpacing),
            TickMath.getSqrtPriceAtTick(upperTick),
            balance0 == 0 ? 0 : uint128(balance0) - 1,
            0
        );

        uint128 liquidity = belowPriceLiquidity + abovePriceLiquidity;
        require(liquidity != 0, ZeroLiquidity());

        Position[] memory positions = new Position[](2);
        uint256 positionCount;

        if (belowPriceLiquidity > 0) {
            positions[positionCount++] = Position({
                tickLower: lowerTick,
                tickUpper: currentTick - tickSpacing,
                liquidity: belowPriceLiquidity,
                salt: bytes32(0)
            });
        }

        if (abovePriceLiquidity > 0) {
            positions[positionCount++] = Position({
                tickLower: currentTick + tickSpacing,
                tickUpper: upperTick,
                liquidity: abovePriceLiquidity,
                salt: bytes32(0)
            });
        }

        // We shrink the positions array to the actual number of positions
        assembly {
            mstore(positions, positionCount)
        }

        data.poolKey.currency0.transfer(address(locker), balance0);
        data.poolKey.currency1.transfer(address(locker), balance1);

        locker.lock(data.poolKey, data.lockDuration, recipient, data.beneficiaries, positions);

        emit Migrate(isToken0 ? token0 : token1, data.poolKey);

        // Not true per se but this value is not used in the Airlock so we'll return 0 to avoid extra computation
        return 0;
    }

    /**
     * @notice Delegates `msg.sender`'s pool authority to another address
     * @param delegatedAuthority Address to delegate to
     */
    function delegateAuthority(address delegatedAuthority) external {
        emit DelegateAuthority(msg.sender, delegatedAuthority);
        getAuthority[msg.sender] = delegatedAuthority;
    }

    /**
     * @notice Associates a Doppler hook with the pool of a given asset
     * @param asset Address to of the targeted asset
     * @param dopplerHook Address of the Doppler hook being associated
     * @param onInitializationCalldata Calldata passed to the Doppler Hook on initialization
     */
    function setDopplerHook(address asset, address dopplerHook, bytes calldata onInitializationCalldata) external {
        Pair memory pair = getPair[asset];
        AssetData memory data = getAssetData[pair.token0][pair.token1];

        PoolStatus status = data.status;
        require(status == PoolStatus.Locked, WrongPoolStatus(uint8(PoolStatus.Locked), uint8(status)));

        (, address timelock,,,,,,,,) = airlock.getAssetData(asset);
        address authority = getAuthority[timelock];
        require(msg.sender == authority || msg.sender == timelock, SenderNotAuthorized());

        uint256 flags = isDopplerHookEnabled[dopplerHook];
        if (dopplerHook != address(0)) {
            require(flags != 0, DopplerHookNotEnabled());

            if (flags & REQUIRES_DYNAMIC_LP_FEE_FLAG != 0 && data.poolKey.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
                revert HookRequiresDynamicLPFee();
            }

            if (ON_INITIALIZATION_FLAG != 0) {
                IDopplerHook(dopplerHook)
                    .onInitialization(asset, getAssetData[pair.token0][pair.token1].poolKey, onInitializationCalldata);
            }
        }

        getAssetData[pair.token0][pair.token1].dopplerHook = dopplerHook;
        emit SetDopplerHook(asset, dopplerHook);
    }

    /**
     * @notice Sets the state of a given Doppler hooks array
     * @param dopplerHooks Array of Doppler hook addresses
     * @param flags Array of flags to set (see flags in BaseDopplerHook.sol)
     */
    function setDopplerHookState(address[] calldata dopplerHooks, uint256[] calldata flags) external {
        require(msg.sender == airlock.owner(), SenderNotAirlockOwner());
        uint256 length = dopplerHooks.length;
        require(length == flags.length, ArrayLengthsMismatch());

        for (uint256 i; i != length; i++) {
            isDopplerHookEnabled[dopplerHooks[i]] = flags[i];
            emit SetDopplerHookState(dopplerHooks[i], flags[i]);
        }
    }

    /**
     * @notice Updates the LP fee for a given asset's pool
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @param lpFee New dynamic LP fee to set
     */
    function updateDynamicLPFee(address asset, uint24 lpFee) external {
        Pair memory pair = getPair[asset];
        AssetData memory data = getAssetData[pair.token0][pair.token1];
        PoolStatus status = data.status;

        require(status == PoolStatus.Locked, WrongPoolStatus(uint8(PoolStatus.Locked), uint8(status)));
        require(data.poolKey.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, PoolNotDynamicFee());
        require(msg.sender == data.dopplerHook, SenderNotAuthorized());
        require(lpFee <= MAX_LP_FEE, LPFeeTooHigh(MAX_LP_FEE, lpFee));

        poolManager.updateDynamicLPFee(data.poolKey, lpFee);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        require(sender == address(this), OnlySelf());
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        AssetData memory assetData = getAssetData[Currency.unwrap(key.currency0)][Currency.unwrap(key.currency1)];
        address dopplerHook = assetData.dopplerHook;

        int128 delta;

        if (dopplerHook != address(0) && isDopplerHookEnabled[dopplerHook] & ON_SWAP_FLAG != 0) {
            Currency feeCurrency;
            (feeCurrency, delta) = IDopplerHook(dopplerHook).onSwap(sender, key, params, balanceDelta, hookData);

            if (delta > 0) {
                poolManager.take(feeCurrency, address(this), uint128(delta));
                poolManager.sync(feeCurrency);

                if (feeCurrency.isAddressZero()) {
                    poolManager.settleFor{ value: uint128(delta) }(dopplerHook);
                } else {
                    feeCurrency.transfer(address(poolManager), uint128(delta));
                    poolManager.settleFor(dopplerHook);
                }
            }
        }

        emit Swap(sender, key, key.toId(), params, balanceDelta.amount0(), balanceDelta.amount1(), hookData);
        return (BaseHook.afterSwap.selector, delta);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Dummy function to pass to `storeBeneficiaries` since we only want to validate the beneficiaries here
    function _storeBeneficiary(PoolId, BeneficiaryData memory) private { }
}
