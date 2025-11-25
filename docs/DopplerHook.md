# Doppler Hooks

## Overview

Doppler Hooks are a set of callback functions that can be called during the lifecycle of "locked" pools initialized by the `DopplerHookMulticurveInitializer` contract. Three main events will trigger these hooks:

- `initialization`: when a new pool is created
- `swap`: when a swap occurs in the pool
- `graduation`: when the pool reaches a certain price maturity

Additionally, pools associated with a Doppler Hook can have their LP fee updated by the associated timelock governance contract or a delegated address.

A couple of things to note:

- A pool initialized without a Doppler Hook can opt-in to use one later via the `setHook` function
- A pool initialized with a Doppler Hook can opt-out of using it later by setting the hook address to `address(0)`
- A pool can change its associated Doppler Hook to a different one at any time via the `setHook` function
- Doppler Hooks are approved by the protocol multisig

## Implementation

Here are the different callback functions available for the Doppler Hooks, note that they can be implemented selectively based on the use case:

| Callback Function                                                                     | Triggered By                                                                                                                                          |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `onInitialization(address, PoolKey calldata, bytes calldata)`                         | - `initialize()` if a `dopplerHook` address is set in the `InitData`<br />- `setDopplerHook()` if a Doppler Hook is set after the pool initialization |
| `onSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)` | `afterSwap` before each swap happening in the Uniswap V4 pool                                                                                         |
| `onGraduation(address, PoolKey calldata, bytes calldata)`                             | `graduate` if the graduation conditions are met (e.g. `farTick` reached)                                                                              |
