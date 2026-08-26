# RehypeDopplerHookInitializer

## Overview

This page documents the initializer-side `RehypeDopplerHookInitializer` contract, which is the Doppler Hook designed to be attached to pools created by [`DopplerHookInitializer`](./DopplerHookInitializer.md). Its authorized [`Bundler`](./Bundler.md) can atomically create a pool and execute its first asset purchase with a one-swap fee exemption.

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
- exempt the Bundler's atomic first buy from non-owner Rehype fees
- reserve an independently routed integrator share of each gross hook fee

Important: this fee schedule controls the Rehype hook fee collected in `onSwap`. It does not update the Uniswap v4 LP fee for the pool.

Also note that initializer-side Rehype pools do not use `getHookFees(poolId).customFee` as their source of truth. The configured fee lives in `getFeeSchedule(poolId)`, and `customFee` remains `0`.

## Initialization Data

On `onInitialization`, the hook decodes `RehypeTypes.InitData` and stores:

| Field | Meaning |
| --- | --- |
| `numeraire` | Quote token; must equal the `PoolKey` currency paired with `asset` |
| `buybackDst` | Recipient for direct buybacks and legacy empty-array beneficiary claims |
| `startFee` | Hook fee at schedule start, in millionths |
| `endFee` | Terminal hook fee after decay completes, in millionths |
| `durationSeconds` | Linear decay duration |
| `startingTime` | Fee schedule start time |
| `feeRoutingMode` | Whether buyback-designated fees are transferred immediately or routed into beneficiary accounting |
| `feeDistributionInfo` | Eight `uint64` WAD weights forming the asset-side and numeraire-side fee split config |
| `feeBeneficiaries` | Optional ordinary Rehype fee recipients and WAD shares over post-owner beneficiary accounting; an empty array preserves legacy `buybackDst` claims |
| `integratorConfig` | `IntegratorInitConfig` containing the integrator, immutable fee share, conversion ratios, and automatic payout setting |

The hook validates the configuration as follows:

- `asset` must be one of the immutable initializer-supplied `PoolKey` currencies, and `numeraire` must equal the other currency; the hook stores that derived currency rather than trusting `initData`
- both `startFee` and `endFee` must be `<= MAX_SWAP_FEE`
- `startFee` must be `>= endFee`
- if `startFee > endFee`, `durationSeconds` must be non-zero
- each row of `feeDistributionInfo` must sum to `WAD`
- `startingTime` is normalized to `block.timestamp` when it is `0` or already in the past
- a non-empty `feeBeneficiaries` array requires `RouteToBeneficiaryFees`
- fee beneficiary addresses must be unique, non-zero, and sorted in ascending order
- each fee beneficiary share must be positive and all shares must sum to `WAD`
- the current Airlock owner need not appear; if included, it is an ordinary beneficiary and may have any positive share
- `integratorConfig.feeShare` must be at most `750_000` (75%)
- when `feeShare` is positive, `integrator` must be non-zero and each independent conversion ratio must be at most
  `1_000_000_000`
- when `feeShare` is zero, `integrator` and both conversion ratios must also be zero

It also initializes a full-range LP position record for later reinvestment.

## Fee Schedule

The hook stores a `FeeSchedule` per pool:

- before `startingTime`, the active fee is `startFee`
- after `startingTime`, the fee decays linearly toward `endFee`
- once the full duration has elapsed, the fee stays at `endFee`
- for flat schedules (`startFee == endFee`), the fee never changes
- `lastFee` caches the last applied value and `FeeUpdated` is emitted only when the fee decreases
- `integratorFeeShare` is packed into the same storage slot but exposed separately through
  `getIntegratorFeeShare(poolId)`

This makes the fee schedule lazy: it is evaluated when swaps happen, not by a background process.

## Swap Behavior

All fee logic runs in `onSwap`.

For each ordinary external swap:

1. The hook ignores internal self-swaps so it does not charge itself during its own rebalance or buyback operations.
2. It computes the current Rehype fee from the schedule.
3. It computes the fee from the swap's unspecified token amount.
4. It self-collects that fee with `poolManager.take(...)`.
5. It returns the same positive `hookDelta` back to `DopplerHookInitializer`, which makes the swap accounting reflect the fee and settles the external hook's delta.
6. It reserves `floor(grossFee * 500 / 10_000)` in the separate Airlock owner bucket.
7. Unless the atomic dev-buy exemption applies, it reserves
   `floor(grossFee * integratorFeeShare / 1_000_000)` in a separate integrator bucket.
8. It sends the exact residual into the fee-distribution matrix, preserving conservation despite integer rounding.

### Atomic Dev Buy

`RehypeDopplerHookInitializer` stores an immutable authorized `bundler`. When `onInitialization` runs inside `Airlock.create`, the hook opens a transient, pool-specific exemption. The exemption can be consumed only by one swap whose PoolManager sender is that Bundler, and it expires at the end of the transaction.

For the exempt swap, the hook still computes the normal gross Rehype fee and reserves the usual 5% Airlock-owner share. It collects and returns only that owner share as the hook delta; both the integrator share and residual fee-distribution share are zero. The dev buy therefore does not add integrator, beneficiary, buyback, or LP-reinvestment fees. Any later swap uses the ordinary fee path above.

The exemption is available only during the atomic create-and-buy flow. Direct creators and ordinary swap routers cannot consume it. A reverted create or buy rolls back both pool creation and transient exemption state.

For each currency, the hook compares the combined residual fee-distribution and pending integrator balance to `EPSILON`. It stops and waits for more fees only while both combined currency balances remain below the threshold.

Once enough fees have accumulated, the hook routes them according to `feeDistributionInfo`:

- asset fees can be sent directly as asset buyback, swapped into numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment
- numeraire fees can be swapped into asset buyback, sent directly as numeraire buyback, accrued as beneficiary fees, or allocated to LP reinvestment

The routing matrix therefore operates only on the residual after the Airlock owner and integrator shares. When multiple beneficiaries are configured, their shares total `WAD` over the portion that ultimately reaches `beneficiaryFees0/1` after buyback routing, swaps, and LP handling—not over the gross hook fee or the entire residual.

## Fee Routing Modes

`RehypeDopplerHook` supports two routing modes:

| Mode | Behavior |
| --- | --- |
| `DirectBuyback` | Buyback-designated outputs are transferred immediately to `buybackDst`; `feeBeneficiaries` must be empty |
| `RouteToBeneficiaryFees` | Buyback-designated outputs are added to beneficiary fee accounting instead of being transferred immediately |

When `feeBeneficiaries` is empty, Rehype's `beneficiaryFees` are ultimately claimed to `buybackDst` as before. When the array is non-empty, `buybackDst` is not used as the beneficiary-fee recipient; configured beneficiaries claim their WAD shares through `FeesManager` accounting.

Rehype fee beneficiaries are separate from the locked pool LP beneficiary shares managed by `DopplerHookInitializer`. A zero LP fee therefore produces no claimable LP fees even when the Rehype hook is charging and distributing its own fee.

## Integrator Fees

The integrator share is parallel to the Airlock-owner share and the residual fees sent to the fee-distribution config. It is not a beneficiary share and is unaffected by `feeDistributionInfo` or later `setFeeDistribution` calls. The configured fee share is immutable, the current integrator may atomically update both conversion ratios, enable or disable automatic payout, or rotate the integrator role.

`IntegratorInitConfig` contains:

- `integrator`: address controlling routing configuration and claims and receiving automatic payouts
- `feeShare`: immutable share of gross Rehype fees using a `1e6` denominator
- `assetFeesToNumeraireRatio`: ratio of asset-denominated integrator fees converted to numeraire using a `1e9` denominator
- `numeraireFeesToAssetRatio`: ratio of numeraire-denominated integrator fees converted to asset using a `1e9` denominator
- `automaticPayout`: whether processed fees are transferred automatically or accrued

Conversion ratios apply per source currency, not as value-based portfolio targets. The amount excluded from conversion stays in its source currency.

Integrator and residual fee-distribution inputs requesting the same swap direction are combined into one internal swap. Actual input consumed and output received are divided proportionally, with the rounding remainder going to the residual fee-distribution amount. If conversion simulation fails or consumes less than requested, the unconverted integrator input becomes claimable in its source currency and never enters the fee-distribution config.

Pending integrator fees have been collected but are not yet processed by a routing cycle. Claimable integrator fees have been processed and retained for manual claim. When automatic payout is disabled, all processed integrator balances become claimable. When it is enabled, the hook attempts one automatic transfer per output currency. A failed native or ERC-20 transfer becomes claimable instead of reverting the user's swap. Native automatic payouts use Solady's bounded `GAS_STIPEND_NO_GRIEF`.

## Updating Fee Distribution

The stored `buybackDst` can call `setFeeDistribution(poolId, ...)` to replace all eight weights in the pool's fee distribution config. The external setter and getter retain their original `uint256` ABI while the values are stored as packed `uint64` WAD weights. The caller must exactly match `getPoolInfo(poolId).buybackDst`, and both the asset-fee row and the numeraire-fee row must each sum to `WAD`.

This authority applies whether `feeBeneficiaries` is empty or configured. With configured beneficiaries, `buybackDst` controls the routing matrix but does not receive beneficiary fees unless it is also included as a beneficiary. Updating the matrix does not change `feeRoutingMode`, the fee schedule, or beneficiary shares.

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

Integrator fees use a separate claim path:

- only the current configured integrator may call `claimIntegratorFees(asset, to)`
- `to` may differ from the integrator but must be non-zero
- a claim transfers all claimable currency0 and currency1 balances
- balances are cleared before transfer, and claim transfers revert on failure
- rotating the integrator moves control of existing claimable balances to the new address

All claim functions are `nonReentrant`.

This feature is specific to `RehypeDopplerHookInitializer`. Rehype migrator initialization data and claim behavior are unchanged.

## Readable State

The main per-pool views are:

- `getPoolInfo(poolId)`
- `getFeeDistributionInfo(poolId)`
- `getFeeRoutingMode(poolId)`
- `getFeeSchedule(poolId)`
- `getIntegratorFeeShare(poolId)`
- `getHookFees(poolId)`
- `getIntegratorRoutingConfig(poolId)`
- `getPendingIntegratorFees(poolId)`
- `getClaimableIntegratorFees(poolId)`
- `getPosition(poolId)`
- `getPoolKey(poolId)`
- `getShares(poolId, beneficiary)`
- `getCumulatedFees0/1(poolId)`
- `bundler`

Together they describe the configured fee schedule, the routing mode, the current fee balances, and the reinvested LP position state.
