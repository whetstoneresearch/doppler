# Doppler Hooks

## Overview

Doppler Hooks are a set of callback functions that can be called during the lifecycle of "locked" pools initialized by a the Multicurve contract. Three main events will trigger these hooks:

- `initialization`: when a new pool is created
- `swap`: when a swap occurs in the pool
- `graduation`: when the pool reaches a certain price maturity

Additionally, pools associated with a Doppler Hook can have their LP fee updated by the associated timelock governance contract or a delegated address.

A couple of things to note:

- A pool initialized without a Doppler Hook can opt-in to use one later via the `setHook` function
- A pool initialized with a Doppler Hook can opt-out of using it later by setting the hook address to `address(0)`
- A pool can change its associated Doppler Hook to a different one at any time via the `setHook` function

## Implementation

Here are the different callback functions provided by the Doppler Hook system:

| Callback Function                                                                     | Triggered By                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `onInitialization(address, bytes calldata)`                                           | - `initialize()` in `DookMulticurveInitializer` if a `dook` address is set in the `InitData`<br />- `setDook()` in `DookMulticurveInitializer` if a dook is set after the pool initialization |
| `onSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)` | `beforeSwap` in the `DookMulticurveHook` contract before each swap happening in the Uniswap V4 pool                                                                                           |
| `onGraduation(address, bytes calldata)`                                               | `graduate` in `DookMulticurveInitializer` if the graduation conditions are met (e.g. `farTick` reached)                                                                                       |
