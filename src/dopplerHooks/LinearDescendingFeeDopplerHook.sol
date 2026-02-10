// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseDopplerHook } from "src/base/BaseDopplerHook.sol";

// Maximum LP fee allowed by the initializer (1_000_000 = 100%)
uint24 constant MAX_LP_FEE = 100_000;

/// @notice Thrown when the configured fee exceeds MAX_LP_FEE
error FeeTooHigh(uint24 fee);

/// @notice Thrown when start fee is below end fee (ascending schedule is not supported)
error InvalidFeeRange(uint24 startFee, uint24 endFee);

/// @notice Thrown when descending schedule has zero duration
error InvalidDurationBlocks(uint64 durationBlocks);

/**
 * @notice Emitted when a new fee schedule is set for a pool
 * @param poolId The pool id
 * @param asset The asset used to route `updateDynamicLPFee`
 * @param startFee The schedule starting fee
 * @param endFee The schedule ending fee
 * @param startBlock The block at which the schedule starts
 * @param durationBlocks Number of blocks over which the fee linearly descends
 */
event FeeScheduleSet(
    PoolId indexed poolId,
    address indexed asset,
    uint24 startFee,
    uint24 endFee,
    uint64 startBlock,
    uint64 durationBlocks
);

/**
 * @notice Emitted when LP fee is updated by this hook
 * @param poolId The pool id
 * @param lpFee The new LP fee
 */
event FeeUpdated(PoolId indexed poolId, uint24 lpFee);

/**
 * @notice Parameters passed in `onInitialization` hook data
 * @param startFee Initial fee at schedule start
 * @param endFee Terminal fee after schedule completion
 * @param durationBlocks Number of blocks for linear descent
 */
struct FeeScheduleParams {
    uint24 startFee;
    uint24 endFee;
    uint64 durationBlocks;
}

/**
 * @notice Fee schedule state for each pool
 * @param asset Asset passed to initializer when updating dynamic LP fee
 * @param startFee Fee at schedule start
 * @param endFee Fee at schedule end
 * @param lastFee Last applied fee
 * @param startBlock Schedule start block
 * @param durationBlocks Number of blocks for schedule completion
 * @param enabled Whether schedule is still active
 */
struct FeeSchedule {
    address asset;
    uint24 startFee;
    uint24 endFee;
    uint24 lastFee;
    uint64 startBlock;
    uint64 durationBlocks;
    bool enabled;
}

interface IDynamicLPFeeUpdater {
    function updateDynamicLPFee(address asset, uint24 lpFee) external;
}

/**
 * @title Linear Descending Fee Doppler Hook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Applies a monotone linear LP fee descent over blocks. This is equivalent to
 * "inverted vesting": fee starts high and linearly approaches a lower terminal fee.
 */
contract LinearDescendingFeeDopplerHook is BaseDopplerHook {
    /// @notice Returns fee schedule state for a pool
    mapping(PoolId poolId => FeeSchedule schedule) public getFeeScheduleOf;

    /// @param initializer Address of a Doppler hook initializer implementing `updateDynamicLPFee`
    constructor(address initializer) BaseDopplerHook(initializer) { }

    /// @inheritdoc BaseDopplerHook
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal override {
        FeeScheduleParams memory params = abi.decode(data, (FeeScheduleParams));
        require(params.startFee <= MAX_LP_FEE, FeeTooHigh(params.startFee));
        require(params.endFee <= MAX_LP_FEE, FeeTooHigh(params.endFee));
        require(params.startFee >= params.endFee, InvalidFeeRange(params.startFee, params.endFee));

        bool isDescending = params.startFee > params.endFee;
        if (isDescending) {
            require(params.durationBlocks > 0, InvalidDurationBlocks(params.durationBlocks));
        }

        PoolId poolId = key.toId();
        getFeeScheduleOf[poolId] = FeeSchedule({
            asset: asset,
            startFee: params.startFee,
            endFee: params.endFee,
            lastFee: params.startFee,
            startBlock: uint64(block.number),
            durationBlocks: params.durationBlocks,
            enabled: isDescending
        });

        emit FeeScheduleSet(poolId, asset, params.startFee, params.endFee, uint64(block.number), params.durationBlocks);
    }

    /// @inheritdoc BaseDopplerHook
    function _onSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (Currency, int128) {
        PoolId poolId = key.toId();
        FeeSchedule storage schedule = getFeeScheduleOf[poolId];

        if (!schedule.enabled) return (Currency.wrap(address(0)), 0);

        uint24 currentFee = _computeCurrentFee(schedule);
        if (currentFee < schedule.lastFee) {
            IDynamicLPFeeUpdater(INITIALIZER).updateDynamicLPFee(schedule.asset, currentFee);
            schedule.lastFee = currentFee;
            emit FeeUpdated(poolId, currentFee);
        }

        if (currentFee == schedule.endFee) {
            schedule.enabled = false;
        }

        return (Currency.wrap(address(0)), 0);
    }

    function _computeCurrentFee(FeeSchedule memory schedule) internal view returns (uint24) {
        if (block.number <= schedule.startBlock) return schedule.startFee;

        uint256 elapsed = block.number - schedule.startBlock;
        if (elapsed >= schedule.durationBlocks) return schedule.endFee;

        uint256 feeDelta = uint256(schedule.startFee - schedule.endFee) * elapsed / schedule.durationBlocks;
        return uint24(uint256(schedule.startFee) - feeDelta);
    }
}
