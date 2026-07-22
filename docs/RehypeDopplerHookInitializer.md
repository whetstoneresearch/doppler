# RehypeDopplerHookInitializer

## Overview

This page documents the initializer-side `RehypeDopplerHook` contract, which is the Doppler Hook designed to be attached to pools created by [`DopplerHookInitializer`](./DopplerHookInitializer.md).

`RehypeDopplerHook` implements two pieces of hook logic:

- `onInitialization`, which stores per-pool fee configuration
- `onSwap`, which collects and routes Rehype fees after swaps

It does not implement custom `onGraduation` behavior. In practice, the expected hook registration is:

- `ON_INITIALIZATION_FLAG`
- `ON_SWAP_FLAG`

## What This Hook Does

At a high level, `RehypeDopplerHook` adds a post-swap fee layer on top of a Doppler pool. For each supported pool, it can:

- charge a Rehype hook fee on swaps
- decay that hook fee from `startFee` to `endFee` over time
- reserve 5% of each gross hook fee for the current Airlock owner
- split collected fees across buybacks, beneficiary accounting, and LP reinvestment
- optionally split Rehype beneficiary fees among multiple pull-based recipients

Important: this fee schedule controls the Rehype hook fee collected in `onSwap`. It does not update the Uniswap v4 LP fee for the pool.

Also note that initializer-side Rehype pools do not use `getHookFees(poolId).customFee` as their source of truth. The configured fee lives in `getFeeSchedule(poolId)`, and `customFee` remains `0`.

## Initialization Data

On `onInitialization`, the hook decodes `RehypeTypes.InitData` and stores:

| Field | Meaning |
| --- | --- |
| `numeraire` | Quote token used by the pool |
| `buybackDst` | Recipient for direct buybacks and legacy empty-array beneficiary claims |
| `startFee` | Hook fee at schedule start, in millionths |
| `endFee` | Terminal hook fee after decay completes, in millionths |
| `durationSeconds` | Linear decay duration |
| `startingTime` | Fee schedule start time |
| `feeRoutingMode` | Whether buyback-designated fees are transferred immediately or routed into beneficiary accounting |
| `feeDistributionInfo` | Fee split matrix for asset-side and numeraire-side fees |
| `feeBeneficiaries` | Optional ordinary Rehype fee recipients and WAD shares over post-owner beneficiary accounting; an empty array preserves legacy `buybackDst` claims |

The hook validates the configuration as follows:

- both `startFee` and `endFee` must be `<= MAX_SWAP_FEE`
- `startFee` must be `>= endFee`
- if `startFee > endFee`, `durationSeconds` must be non-zero
- each row of `feeDistributionInfo` must sum to `WAD`
- `startingTime` is normalized to `block.timestamp` when it is `0` or already in the past
- a non-empty `feeBeneficiaries` array requires `RouteToBeneficiaryFees`
- fee beneficiary addresses must be unique, non-zero, and sorted in ascending order
- each fee beneficiary share must be positive and all shares must sum to `WAD`
- the current Airlock owner need not appear; if included, it is an ordinary beneficiary and may have any positive share

It also initializes a full-range LP position record for later reinvestment.

## Fee Schedule

The hook stores a `FeeSchedule` per pool:

- before `startingTime`, the active fee is `startFee`
- after `startingTime`, the fee decays linearly toward `endFee`
- once the full duration has elapsed, the fee stays at `endFee`
- for flat schedules (`startFee == endFee`), the fee never changes
- `lastFee` caches the last applied value and `FeeUpdated` is emitted only when the fee decreases

This makes the fee schedule lazy: it is evaluated when swaps happen, not by a background process.

## Swap Behavior

All fee logic runs in `onSwap`.

For each external swap:

1. The hook ignores internal self-swaps so it does not charge itself during its own rebalance or buyback operations.
2. It computes the current Rehype fee from the schedule.
3. It computes the fee from the swap's unspecified token amount.
4. It self-collects that fee with `poolManager.take(...)`.
5. It returns the same positive `hookDelta` back to `DopplerHookInitializer`, which makes the swap accounting reflect the fee and settles the external hook's delta.
6. It reserves `floor(grossFee * 500 / 10_000)` in the separate Airlock owner bucket, regardless of whether `feeBeneficiaries` is empty.
7. It accumulates exactly `grossFee - ownerCut` into the per-pool balances used by normal routing.

If both accumulated fee balances are still below `EPSILON`, the hook stops there and waits for more fees to build up.

Once enough fees have accumulated, the hook routes them according to `feeDistributionInfo`:

- asset fees can be sent directly as asset buyback, swapped into numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment
- numeraire fees can be swapped into asset buyback, sent directly as numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment

The routing matrix therefore operates only on the post-owner amount. When multiple beneficiaries are configured, their shares total `WAD` over the portion that ultimately reaches `beneficiaryFees0/1` after buyback routing, swaps, and LP handling—not over the gross hook fee or the entire post-owner remainder.

## Fee Routing Modes

`RehypeDopplerHook` supports two routing modes:

| Mode | Behavior |
| --- | --- |
| `DirectBuyback` | Buyback-designated outputs are transferred immediately to `buybackDst`; `feeBeneficiaries` must be empty |
| `RouteToBeneficiaryFees` | Buyback-designated outputs are added to beneficiary fee accounting instead of being transferred immediately |

When `feeBeneficiaries` is empty, Rehype's `beneficiaryFees` are ultimately claimed to `buybackDst` as before. When the array is non-empty, `buybackDst` is not used as the beneficiary-fee recipient; configured beneficiaries claim their WAD shares through `FeesManager` accounting.

Rehype fee beneficiaries are separate from the locked pool LP beneficiary shares managed by `DopplerHookInitializer`. A zero LP fee therefore produces no claimable LP fees even when the Rehype hook is charging and distributing its own fee.

## LP Reinvestment

The LP-designated portions of collected fees are not simply parked. The hook:

- computes the token imbalance against a full-range LP position
- optionally performs an internal swap to rebalance the fee inventory
- adds the balanced amounts back into a full-range position for the pool

Any leftovers after buybacks and LP reinvestment are rolled into `beneficiaryFees0` and `beneficiaryFees1`.

## Claims

Legacy pools with an empty `feeBeneficiaries` array retain the existing claim paths:

- `collectFees(asset)`: transfers accumulated `beneficiaryFees0/1` to `buybackDst`
- `claimAirlockOwnerFees(asset)`: transfers accumulated `airlockOwnerFees0/1` to the current Airlock owner

For pools with configured fee beneficiaries:

- harvesting is permissionless through either `collectFees(asset)` or `collectFees(poolId)`
- either call moves the pending beneficiary fee bucket into cumulative `FeesManager` accounting, then releases only the caller's accrued ordinary share
- a caller with zero shares can harvest on behalf of the configured beneficiaries but receives zero
- each ordinary beneficiary claims through `collectFees` and may move its share with `updateBeneficiary`

`collectFees(poolId)` is available only for pools with configured beneficiaries; it reverts for legacy or unknown pool IDs rather than consuming their legacy beneficiary bucket.

The role-based owner cut is separate in both modes. Only the current `airlock.owner()` can call `claimAirlockOwnerFees(asset)`, and it receives the entire unclaimed owner bucket even if some fees accrued before an ownership transfer. The former owner loses access to that role bucket. If an owner is also listed as an ordinary beneficiary, that ordinary share continues to use `collectFees` and `updateBeneficiary`; it remains attached to the listed address and does not migrate when Airlock ownership changes.

All claim functions are `nonReentrant`.

This feature is specific to `RehypeDopplerHookInitializer`. Rehype migrator initialization data and claim behavior are unchanged.

## Readable State

The main per-pool views are:

- `getPoolInfo(poolId)`
- `getFeeDistributionInfo(poolId)`
- `getFeeRoutingMode(poolId)`
- `getFeeSchedule(poolId)`
- `getHookFees(poolId)`
- `getPosition(poolId)`
- `getPoolKey(poolId)`
- `getShares(poolId, beneficiary)`
- `getCumulatedFees0/1(poolId)`

Together they describe the configured fee schedule, the routing mode, the current fee balances, and the reinvested LP position state.
