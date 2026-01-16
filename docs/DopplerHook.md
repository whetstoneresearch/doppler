# Doppler Hooks

## Overview

Doppler Hooks are a set of callback functions that can be called during the lifecycle of "locked" pools initialized by the `DopplerHookInitializer` contract. Three main events will trigger these hooks:

- `initialization`: when a new pool is created
- `swap`: when a swap occurs in the pool
- `graduation`: when the pool reaches a certain price maturity

Additionally, pools associated with a Doppler Hook can have their LP fee updated by the associated timelock governance contract or a delegated address.

A couple of things to note:

- A pool initialized without a Doppler Hook can opt-in to use one later via the `setHook` function
- A pool initialized with a Doppler Hook can opt-out of using it later by setting the hook address to `address(0)`
- A pool can change its associated Doppler Hook to a different one at any time via the `setHook` function
- Doppler Hooks are approved by the protocol multisig
- A pool without a Doppler Hook cannot be initialized with a dynamic LP fee

## Implementation

Here are the different callback functions available for the Doppler Hooks, note that they can be implemented selectively based on the use case:

| Callback Function                                                                                                                                                                | Triggered By                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `onInitialization(address asset, PoolKey calldata key, bytes calldata data`                                                                                                      | - `initialize()` if a `dopplerHook` address is set in the `InitData`<br />- `setDopplerHook()` if a Doppler Hook is set after the pool initialization |
| `onSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params,BalanceDelta delta, bytes calldata data) returns (Currency feeCurrency, int128 hookDelta)` | `afterSwap` before each swap happening in the Uniswap V4 pool                                                                                         |
| `onGraduation(address asset, PoolKey calldata key, bytes calldata data)`                                                                                                         | `graduate` if the graduation conditions are met (e.g. `farTick` reached)                                                                              |
