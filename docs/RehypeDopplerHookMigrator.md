# RehypeDopplerHookMigrator

## Overview

This page documents the migrator-side `RehypeDopplerHookMigrator` contract, which is the Doppler Hook designed to be attached to pools created by [`DopplerHookMigrator`](./DopplerHookMigrator.md).

`RehypeDopplerHookMigrator` implements two pieces of hook logic:

- `onInitialization`, which stores per-pool fee configuration
- `onAfterSwap`, which collects and routes Rehype fees after swaps

It does not implement custom `onBeforeSwap` behavior. In practice, the expected hook registration is:

- `ON_INITIALIZATION_FLAG`
- `ON_AFTER_SWAP_FLAG`

## What This Hook Does

At a high level, `RehypeDopplerHookMigrator` adds a post-swap fee layer to a migrated pool. For each supported pool, it can:

- charge a fixed Rehype hook fee on swaps
- split collected fees across buybacks, beneficiary accounting, and LP reinvestment
- carve out a fixed 5% share of the raw hook fee for the Airlock owner

Unlike the initializer-side `RehypeDopplerHook`, this migrator variant uses a static `customFee`. It does not implement a decaying fee schedule.

## Initialization Data

On `onInitialization`, the hook decodes `RehypeTypes.MigratorInitData` and stores:

| Field | Meaning |
| --- | --- |
| `numeraire` | Quote token used by the pool |
| `buybackDst` | Recipient for direct buybacks and claimed beneficiary fees |
| `customFee` | Static hook fee, in millionths |
| `feeRoutingMode` | Whether buyback-designated fees are transferred immediately or routed into beneficiary accounting |
| `feeDistributionInfo` | Fee split matrix for asset-side and numeraire-side fees |

The hook validates that each row of `feeDistributionInfo` sums to `WAD`, stores the static fee in `getHookFees(poolId).customFee`, and initializes a full-range LP position record for later reinvestment.

## Swap Behavior

All fee logic runs in `onAfterSwap`.

For each external swap:

1. The hook ignores internal self-swaps so it does not charge itself during its own rebalance or buyback operations.
2. It computes the fee from the swap's unspecified token amount using the configured `customFee`.
3. It self-collects that fee with `poolManager.take(...)`.
4. It returns the same positive `hookDelta` back to `DopplerHookMigrator`, which makes the swap accounting reflect the fee and settles the external hook's delta.
5. It takes 5% of the raw fee for the Airlock owner.
6. It accumulates the remaining 95% into per-pool fee balances.

If both accumulated fee balances are still below `EPSILON`, the hook stops there and waits for more fees to build up.

Once enough fees have accumulated, the hook routes them according to `feeDistributionInfo`:

- asset fees can be sent directly as asset buyback, swapped into numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment
- numeraire fees can be swapped into asset buyback, sent directly as numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment

## Fee Routing Modes

`RehypeDopplerHookMigrator` supports two routing modes:

| Mode | Behavior |
| --- | --- |
| `DirectBuyback` | Buyback-designated outputs are transferred immediately to `buybackDst` |
| `RouteToBeneficiaryFees` | Buyback-designated outputs are added to beneficiary fee accounting instead of being transferred immediately |

Note that Rehype's `beneficiaryFees` are internal hook accounting and are ultimately claimed to `buybackDst`. They are separate from the beneficiary configuration used by the migrator's liquidity-locking flow.

## LP Reinvestment

The LP-designated portions of collected fees are not simply parked. The hook:

- computes the token imbalance against a full-range LP position
- optionally performs an internal swap to rebalance the fee inventory
- adds the balanced amounts back into a full-range position for the pool

Any leftovers after buybacks and LP reinvestment are rolled into `beneficiaryFees0` and `beneficiaryFees1`.

## Claims and Configuration

The hook exposes three public management paths:

- `collectFees(asset)`: transfers accumulated `beneficiaryFees0/1` to `buybackDst`
- `claimAirlockOwnerFees(asset)`: transfers accumulated `airlockOwnerFees0/1` to the current Airlock owner
- `setFeeDistribution(poolId, ...)`: lets `buybackDst` update the fee split matrix for that pool

`customFee` itself is fixed at initialization time and is not updated by this contract.

## Pool Resolution

The migrator-side hook identifies pools from the asset address:

- `MIGRATOR.getPair(asset)` resolves the token pair
- `MIGRATOR.getAssetData(token0, token1)` returns the `PoolKey`

This is why `collectFees(asset)` and `claimAirlockOwnerFees(asset)` both take the asset address instead of a `PoolId`.

## Readable State

The main per-pool views are:

- `getPoolInfo(poolId)`
- `getFeeDistributionInfo(poolId)`
- `getFeeRoutingMode(poolId)`
- `getHookFees(poolId)`
- `getPosition(poolId)`

Together they describe the configured static fee, the routing mode, the current fee balances, and the reinvested LP position state.
