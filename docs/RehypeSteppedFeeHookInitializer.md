# RehypeSteppedFeeHookInitializer Delta Spec

## Purpose

`RehypeSteppedFeeHookInitializer` is an additive Rehype hook variant for pools created by [`DopplerHookInitializer`](./DopplerHookInitializer.md).

It exists only to change the initializer-side Rehype fee schedule from the deployed hook's single linear decay to an immutable stepped fee schedule. All other Rehype behavior should match [`RehypeDopplerHookInitializer`](./RehypeDopplerHookInitializer.md).

This is a redeploy target. It does not modify the deployed `RehypeDopplerHookInitializer`, `RehypeTypes`, `DopplerHookInitializer`, Airlock, or Rehype migrator contracts.

## Delta From Deployed Rehype Hook

Changed:

- contract/file name: `RehypeSteppedFeeHookInitializer`
- init payload type: `SteppedFeeInitData`
- fee schedule model: stepped checkpoints instead of one linear `startFee -> endFee` decay
- runtime state: one packed `FeeScheduleState` plus ordered `FeeCheckpoint[]`

Unchanged:

- `DopplerHookInitializer` callback flow
- hook registration expectations: `ON_INITIALIZATION_FLAG` and `ON_SWAP_FLAG`
- Rehype post-swap fee collection
- fee units and `MAX_SWAP_FEE` cap
- Airlock-owner 5% fee carveout
- fee distribution matrix semantics
- buyback routing modes
- beneficiary fee accounting
- LP reinvestment behavior
- fee claim paths
- no custom `onGraduation` behavior

## Init Data Delta

Deployed Rehype init data has a single `endFee` and `durationSeconds`.

This hook replaces those two fields with ordered input segments:

```solidity
struct SteppedFeeInitData {
    address numeraire;
    address buybackDst;
    uint24 startFee;
    FeeSegment[] feeSegments;
    uint32 startingTime;
    FeeRoutingMode feeRoutingMode;
    FeeDistributionInfo feeDistributionInfo;
}

struct FeeSegment {
    uint24 targetFee;
    uint32 durationSeconds;
}
```

Segment input is duration-based for callers. During initialization, the hook converts it into absolute-time checkpoints:

```solidity
struct FeeCheckpoint {
    uint24 targetFee;
    uint32 endTime;
}
```

`endFee` is the final segment target. The total schedule duration is the sum of all segment durations.

## Validation Delta

The stepped hook validates:

- `startFee <= MAX_SWAP_FEE`
- `feeSegments.length > 0`
- every segment `targetFee <= MAX_SWAP_FEE`
- every segment `targetFee <= previousFee`
- `block.timestamp` must fit the schedule's `uint32` time model
- every checkpoint `endTime` must fit `uint32`
- each `feeDistributionInfo` row sums to `WAD`
- `startingTime` is normalized to `block.timestamp` when it is `0` or already in the past

There is no segment-count cap. The hot path does not scan all checkpoints; only swaps that cross pending checkpoint times pay catch-up gas.

## Fee Semantics Delta

Deployed Rehype:

- linearly interpolates from `startFee` to `endFee` over `durationSeconds`

Stepped Rehype:

- keeps the active fee flat until the next checkpoint time
- jumps to the checkpoint's `targetFee` when `block.timestamp >= endTime`
- consumes multiple due checkpoints in order if a swap crosses more than one checkpoint
- treats `durationSeconds == 0` as an immediate checkpoint
- treats `targetFee == previousFee` as a plateau
- treats one segment with `targetFee == startFee` as a flat fee schedule

Example:

```solidity
startFee = 800_000;
feeSegments = [
    FeeSegment({ targetFee: 100_000, durationSeconds: 30 }),
    FeeSegment({ targetFee: 10_000, durationSeconds: 300 })
];
```

Active fee:

- `800_000` before `startingTime + 30`
- `100_000` from `startingTime + 30` through before `startingTime + 330`
- `10_000` from `startingTime + 330` onward

## Runtime State Delta

Deployed Rehype stores `FeeSchedule` with `lastFee` for linear decay.

This hook stores:

```solidity
struct FeeScheduleState {
    uint32 startTime;
    uint32 nextTime;
    uint32 nextIndex;
    uint32 checkpointCount;
    uint24 startFee;
    uint24 currentFee;
    uint24 endFee;
}
```

`FeeScheduleState` fits in one storage slot.

No-update swap path:

1. read `getFeeSchedule(poolId)`
2. return `startFee` before `startTime`
3. return `currentFee` when `nextTime == 0`
4. return `currentFee` when `block.timestamp < nextTime`

Checkpoint storage is read only when at least one checkpoint is due. In that path, the hook:

1. reads `getFeeCheckpoints(poolId, nextIndex)`
2. advances through all due checkpoints
3. writes `getFeeSchedule(poolId)` once
4. emits `FeeUpdated(poolId, currentFee)` if the fee decreased

## Events Delta

Kept from deployed Rehype:

```solidity
event FeeScheduleSet(PoolId indexed poolId, uint32 startingTime, uint24 startFee, uint24 endFee, uint32 durationSeconds);
event FeeUpdated(PoolId indexed poolId, uint24 fee);
```

No per-checkpoint event is emitted. Checkpoints are readable from storage when needed, and initialization calldata already contains the input segment list.

## Read Surface Delta

The main new/read-changed views are compiler-generated mapping getters:

- `getFeeSchedule(poolId)` returns `FeeScheduleState`
- `getFeeCheckpoints(poolId, index)` returns one `FeeCheckpoint`

There are no explicit `getFeeSegmentCount` or `getFeeSegment` wrapper functions.

## Non-Goals

This hook does not:

- edit fee schedules after initialization
- update the Uniswap v4 LP fee
- change pool creation or graduation
- change migrator fee behavior
- change deployed Rehype hook behavior

## Test Requirements

Focused tests should cover:

- schedule state and checkpoint storage
- empty segment list rejection
- target fee cap rejection
- ascending segment rejection
- timestamp overflow rejection
- checkpoint end-time overflow rejection
- flat plateau encoding
- zero-duration immediate checkpoint
- stepped boundary behavior
- catch-up through multiple expired checkpoints
- `FeeUpdated` emission on downward updates
- representative `onSwap` fee collection
- insufficient pool-manager fee-currency balance
