# DopplerHookMigrator

## Overview

The `DopplerHookMigrator` is a `LiquidityMigrator` module that migrates liquidity from an auction pool into a fresh Uniswap V4 pool. It also acts as a Uniswap V4 hook itself (`beforeInitialize` and `afterSwap`), allowing it to gate pool creation and forward swap events to an optional [Doppler Hook](./DopplerHook.md).

It integrates with the [`StreamableFeesLockerV2`](./StreamableFeesLockerV2.md) to lock the migrated liquidity for a configurable duration, and with the [`ProceedsSplitter`](./ProceedsSplitter.md) to optionally distribute a share of the proceeds to a designated recipient during migration.

## Lifecycle

A pool managed by the migrator goes through three statuses:

| Status          | Description                                                           |
| --------------- | --------------------------------------------------------------------- |
| `Uninitialized` | Default state — no asset data has been registered for this token pair |
| `Initialized`   | Asset data has been registered via `initialize`, pool is not yet live |
| `Locked`        | Pool has been created and liquidity locked via `migrate`              |

```mermaid
flowchart LR
    U[Uninitialized] -->|initialize| I[Initialized]
    I -->|migrate| L[Locked]
```

### Initialization

`initialize` is called by the Airlock contract during asset creation. It validates and stores the configuration for the future pool, including fee settings, beneficiaries, the optional Doppler Hook address, and an optional proceeds split. No Uniswap V4 pool is created at this stage.

### Migration

`migrate` is called by the Airlock contract when the auction completes. It:

1. Creates the Uniswap V4 pool at the given price
2. Sets the initial LP fee (fixed or dynamic)
3. Calls `onInitialization` on the Doppler Hook, if one is set
4. Distributes the proceeds split, if configured
5. Adds liquidity as two single-sided positions (below and above the current price) to maximize token usage
6. Transfers the tokens to the `StreamableFeesLockerV2` and locks the positions

See the contract source for details on how liquidity is computed and positions are constructed.

## Features

### Doppler Hook Support

The migrator supports pluggable [Doppler Hooks](./DopplerHook.md) that receive callbacks during the pool lifecycle. Doppler Hooks must be approved by the Airlock owner via `setDopplerHookState` before they can be used. Each hook is registered with a set of flags that determine which callbacks it supports (initialization, swap, graduation, dynamic LP fee).

Key behaviors:

- A Doppler Hook can be set at initialization time or added/changed after migration via `setDopplerHook`
- A pool can opt out of its Doppler Hook by setting the address to `address(0)`
- On every swap, the migrator's `afterSwap` hook forwards the event to the associated Doppler Hook's `onSwap` callback (if the swap flag is enabled), which can return a fee delta

### Dynamic LP Fees

Pools can be configured with either a fixed LP fee or a dynamic LP fee. When using dynamic fees:

- A Doppler Hook that requires dynamic fees (flag `REQUIRES_DYNAMIC_LP_FEE`) cannot be associated with a fixed-fee pool
- The associated Doppler Hook can update the LP fee at any time via `updateDynamicLPFee`
- The maximum LP fee is capped at 15%

### Authority Delegation

After migration, pool governance is managed by the asset's timelock contract. The timelock can delegate its authority to another address via `delegateAuthority`, allowing that address to call `setDopplerHook` on its behalf. This is useful for DAOs that want to grant operational control to a specific address without transferring full timelock ownership.

### Proceeds Splitting

The migrator inherits from `ProceedsSplitter`, enabling a share of the numeraire proceeds to be distributed to a designated recipient during migration. See the [ProceedsSplitter documentation](./ProceedsSplitter.md) for details.

### Liquidity Locking

All migrated liquidity is locked in the `StreamableFeesLockerV2` for a duration specified at initialization time. Fees accrued during the lock period can be streamed to the configured beneficiaries. See the [StreamableFeesLockerV2 documentation](./StreamableFeesLockerV2.md) for details.
