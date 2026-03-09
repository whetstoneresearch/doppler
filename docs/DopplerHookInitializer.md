# DopplerHookInitializer

## Overview

`DopplerHookInitializer` is a `PoolInitializer` for Uniswap v4 multicurve pools that also acts as the pool's hook contract. In addition to placing and managing liquidity, it can forward lifecycle events to an optional external Doppler Hook contract associated with the pool.

The external Doppler Hook is configured per asset and can be set during `initialize()` or later via `setDopplerHook()`.

## Pool Lifecycle

Pools managed by the initializer move through these statuses:

| Status | Description |
| --- | --- |
| `Uninitialized` | Default state before `initialize()` is called |
| `Initialized` | Pool exists and liquidity is live, but there are no locked beneficiaries |
| `Locked` | Pool exists and beneficiary accounting is active |
| `Graduated` | Pool has reached its graduation condition and `graduate()` has executed |
| `Exited` | Liquidity has been removed through `exitLiquidity()` |

Only `Locked` pools can change their associated Doppler Hook or graduate.

## Doppler Hook Callbacks

The initializer can forward three callback types to the configured external Doppler Hook. Each callback is enabled independently through `setDopplerHookState()`.

| Callback | Trigger |
| --- | --- |
| `onInitialization(address asset, PoolKey calldata key, bytes calldata data)` | Called during `initialize()` when a hook is already configured, or during `setDopplerHook()` when a new hook is attached to an existing locked pool |
| `onSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata data) returns (Currency feeCurrency, int128 hookDelta)` | Called from the initializer's `afterSwap` hook after every swap when `ON_SWAP_FLAG` is enabled. A positive `hookDelta` is settled by the initializer to the external hook in `feeCurrency` |
| `onGraduation(address asset, PoolKey calldata key, bytes calldata data)` | Called by `graduate()` when the pool reaches its graduation condition and `ON_GRADUATION_FLAG` is enabled |

## Hook Registration

External Doppler Hooks must be approved by the Airlock owner through `setDopplerHookState(address[] dopplerHooks, uint256[] flags)`.

The available flags are defined in `BaseDopplerHook.sol`:

- `ON_INITIALIZATION_FLAG`
- `ON_SWAP_FLAG`
- `ON_GRADUATION_FLAG`
- `REQUIRES_DYNAMIC_LP_FEE_FLAG`

Key behaviors:

- A pool initialized without a Doppler Hook can later attach one with `setDopplerHook()`
- A pool can opt out by setting the hook to `address(0)`
- A pool can swap from one approved hook to another while it is `Locked`
- `setDopplerHook()` can only be called by the asset timelock or its delegated authority
- `graduate()` only succeeds when a locked pool has a non-zero associated hook with the `ON_GRADUATION_FLAG` enabled

## Dynamic LP Fees

When a pool is initialized with a Doppler Hook, the pool itself is created as a dynamic-fee Uniswap v4 pool and the initializer seeds the initial LP fee with the `fee` field from `InitData`.

The external Doppler Hook associated with a locked pool can later update that LP fee directly through `updateDynamicLPFee()`, subject to the initializer's max LP fee cap.

That also means:

- A pool created without a Doppler Hook keeps the fixed fee from `InitData.fee`
- Adding a hook later with `setDopplerHook()` does not retroactively convert that pool into a dynamic-fee pool
- `onSwap()` itself does not override the pool LP fee on a per-swap basis; it only returns a hook fee delta back through the initializer's `afterSwap` hook
- Any custom fee logic implemented in an external Doppler Hook is distinct from the pool LP fee and is settled through the returned `hookDelta`, not by changing the Uniswap v4 LP fee automatically on each swap
