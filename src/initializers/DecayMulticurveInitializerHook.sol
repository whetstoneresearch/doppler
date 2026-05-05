// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import {
    FeeTooHigh,
    InvalidDurationSeconds,
    InvalidFeeRange,
    MAX_LP_FEE
} from "src/initializers/DecayMulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/initializers/UniswapV4MulticurveInitializerHook.sol";

/**
 * @notice Emitted when a fee schedule is configured for a pool
 * @param poolId Pool id
 * @param startingTime Sale start timestamp
 * @param startFee Fee at schedule start
 * @param endFee Terminal fee after schedule completion
 * @param durationSeconds Number of seconds over which fee linearly descends
 */
event FeeScheduleSet(
    PoolId indexed poolId, uint32 startingTime, uint24 startFee, uint24 endFee, uint32 durationSeconds
);

/**
 * @notice Emitted when LP fee is updated by this hook
 * @param poolId Pool id
 * @param lpFee New LP fee
 */
event FeeUpdated(PoolId indexed poolId, uint24 lpFee);

/**
 * @notice Packed fee schedule for a pool.
 * @dev Fits in a single storage slot to minimize read/write cost in `beforeSwap`.
 * @param startingTime Timestamp where schedule starts
 * @param startFee Fee at schedule start
 * @param endFee Fee at schedule end
 * @param lastFee Last applied fee
 * @param durationSeconds Schedule duration in seconds
 */
struct FeeSchedule {
    uint32 startingTime;
    uint24 startFee;
    uint24 endFee;
    uint24 lastFee;
    uint32 durationSeconds;
}

/**
 * @title Decay Multicurve Hook
 * @author Whetstone Research
 * @notice Hook used by `DecayMulticurveInitializer` to:
 * 1) seed dynamic LP fee at schedule creation
 * 2) update dynamic LP fee in `beforeSwap` using timestamp-based linear decay
 *
 * Swaps are always allowed. If `block.timestamp < startingTime`, the effective
 * fee remains at `startFee` until decay begins.
 */
contract DecayMulticurveInitializerHook is UniswapV4MulticurveInitializerHook {
    using SafeCastLib for uint256;

    /// @notice Fee schedule per pool id
    mapping(PoolId poolId => FeeSchedule schedule) public getFeeScheduleOf;

    /**
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Decay Multicurve Initializer
     */
    constructor(IPoolManager manager, address initializer) UniswapV4MulticurveInitializerHook(manager, initializer) { }

    /**
     * @notice Sets a pool schedule. If `startingTime` is in the past, it is clamped to `block.timestamp`.
     * @param poolKey Pool key
     * @param startingTime Start timestamp
     * @param startFee Starting fee
     * @param endFee Terminal fee
     * @param durationSeconds Descending duration in seconds
     */
    function setSchedule(
        PoolKey calldata poolKey,
        uint32 startingTime,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds
    ) external onlyInitializer(msg.sender) {
        require(startFee <= MAX_LP_FEE, FeeTooHigh(startFee));
        require(endFee <= MAX_LP_FEE, FeeTooHigh(endFee));
        require(startFee >= endFee, InvalidFeeRange(startFee, endFee));

        bool isDescending = startFee > endFee;
        if (isDescending) {
            require(durationSeconds > 0, InvalidDurationSeconds(durationSeconds));
        }

        uint32 normalizedStart = (startingTime <= block.timestamp ? block.timestamp : startingTime).toUint32();
        PoolId poolId = poolKey.toId();
        // Hook is authorized to seed dynamic LP fee immediately.
        poolManager.updateDynamicLPFee(poolKey, startFee);
        getFeeScheduleOf[poolId] = FeeSchedule({
            startingTime: normalizedStart,
            startFee: startFee,
            endFee: endFee,
            lastFee: startFee,
            durationSeconds: durationSeconds
        });

        emit FeeScheduleSet(poolId, normalizedStart, startFee, endFee, durationSeconds);
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        FeeSchedule memory schedule = getFeeScheduleOf[poolId];

        if (schedule.lastFee == schedule.endFee) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (block.timestamp <= schedule.startingTime) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 currentFee;
        uint256 elapsed = block.timestamp - schedule.startingTime;

        if (elapsed >= schedule.durationSeconds) {
            currentFee = schedule.endFee;
        } else {
            currentFee = _computeCurrentFee(schedule, elapsed);
        }

        if (currentFee < schedule.lastFee) {
            poolManager.updateDynamicLPFee(key, currentFee);
            schedule.lastFee = currentFee;
            getFeeScheduleOf[poolId] = schedule;
            emit FeeUpdated(poolId, currentFee);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _computeCurrentFee(FeeSchedule memory schedule, uint256 elapsed) internal pure returns (uint24) {
        uint256 feeRange = uint256(schedule.startFee - schedule.endFee);
        uint256 feeDelta = feeRange * elapsed / schedule.durationSeconds;
        return uint24(uint256(schedule.startFee) - feeDelta);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
