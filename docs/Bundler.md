# Bundler

## Overview

`Bundler` atomically creates a Doppler multicurve market through `Airlock`, buys the newly created asset with an exact amount of its numeraire, and optionally vests the purchased asset for a recipient. The create and buy execute in one transaction: if initialization, the swap, settlement, or vesting setup fails, the complete launch reverts.

The current Bundler supports pools created by `DopplerHookInitializer`, both with and without `RehypeDopplerHookInitializer`. `LockableUniswapV3Initializer` and `UniswapV4Initializer` use different state and execution interfaces and are not supported by this Bundler version. Attempting to bundle those initializer types reverts the entire launch.

## Dependencies

The constructor binds two immutable dependencies:

- `airlock`: creates the asset, governance, timelock, and pool
- `poolManager`: executes and settles the Uniswap v4 purchase

A `RehypeDopplerHookInitializer` that enables atomic dev buys is separately deployed with this Bundler's address as its immutable authorized `bundler`. The deployment scripts deploy Bundler before Rehype and verify that both contracts reference the expected Airlock, PoolManager, and initializer.

## Creating and Buying

Call:

```solidity
bundle(
    CreateParams createData,
    VestingParams vestingData,
    uint128 exactAmountIn,
    address recipient
)
```

The function returns:

- `asset`: created asset address
- `poolKey`: created Uniswap v4 pool key
- `governance`: created governance address
- `timelock`: created timelock address
- `amountOut`: net amount of the created asset purchased

`exactAmountIn` must be non-zero and must be fully consumed by the pool. A swap that reaches its price limit or exhausts available liquidity before spending the full input reverts the entire launch.

The initialized pool must contain exactly the created asset and `createData.numeraire`. Bundler derives the purchase direction from the currencies' canonical ordering; it does not assume that the asset is always `currency0` or `currency1`.

### Funding

For an ERC20 numeraire:

- `msg.value` must be zero
- the caller must own at least `exactAmountIn`
- the caller must approve Bundler to transfer `exactAmountIn`

For native ETH:

- `createData.numeraire` is `address(0)`
- `msg.value` must equal `exactAmountIn` exactly

Bundler settles the input directly with PoolManager and does not retain successful swap input. The purchased asset is transferred either to `recipient` or to Bundler custody when vesting is enabled.

## Rehype Dev Buy

When the created pool uses the authorized `RehypeDopplerHookInitializer`, its initialization opens a pool-specific transient exemption for the Bundler's first swap. That swap pays only the normal Airlock-owner cut of the otherwise assessed Rehype fee. The remaining beneficiary, buyback, and LP-reinvestment portions are not collected for the dev buy.

The exemption is valid for one Bundler swap in the same transaction as `Airlock.create`. It cannot be consumed by a direct creator or ordinary swap router, and it disappears when the transaction completes. Every later swap uses the pool's ordinary Rehype fee schedule and routing configuration.

Pools created through `DopplerHookInitializer` without Rehype still support the atomic create-and-buy flow but receive no Rehype exemption because they do not charge a Rehype fee.

## Optional Vesting

`VestingParams` contains:

- `permissionlessClaim`: whether any address may trigger a claim for the recipient
- `vestingDuration`: seconds from creation until the full purchase is vested
- `cliffDuration`: seconds from creation before any vested amount is claimable

A zero `vestingDuration` disables Bundler vesting and sends `amountOut` directly to `recipient`. Otherwise:

- `cliffDuration` must not exceed `vestingDuration`
- Bundler holds exactly `amountOut`
- vesting begins at the successful bundle timestamp
- no tokens are claimable before the cliff
- after the cliff, cumulative vesting is linear from the start timestamp
- at `start + vestingDuration`, the entire remaining amount is claimable

The cumulative vested amount before completion is:

```text
floor(totalAmount * (block.timestamp - start) / vestingDuration)
```

Claims always transfer to the stored recipient. With `permissionlessClaim = true`, another address may trigger delivery but cannot redirect it. With `permissionlessClaim = false`, only the recipient may call `claim`.

If the created token has an active recipient balance limit, include Bundler among the token factory's balance-limit exclusions when its expected custody balance may exceed that limit. Transfers from Bundler to the final recipient remain subject to the token's configured recipient limit.

### Vesting Views and Claims

- `vestingOf(asset)` returns the stored recipient, permissions, schedule, total amount, and claimed amount
- `claimable(asset)` returns the amount currently available
- `claim(asset)` transfers all currently claimable tokens to the stored recipient

A claim reverts when the asset has no vesting position, nothing new has vested, or a restricted position is called by anyone other than its recipient.

## Simulation

Call:

```solidity
simulateBundle(CreateParams createData, uint128 exactAmountIn)
```

`simulateBundle` executes the same create and swap path in a reverting call frame, then returns the predicted asset, pool key, governance, timelock, and net output. All deployments and state changes are rolled back.

The function is intentionally not `view`, but it needs neither funds nor approval and is intended for offchain `eth_call`. A simulation and later transaction can differ if their underlying chain state differs.

## Events

- `Bundled(recipient, amountIn, amountOut, poolKey)`: emitted after a successful create and purchase
- `VestingCreated(asset, recipient, permissionlessClaim, totalAmount, start, cliffDuration, vestingDuration)`: emitted when custody vesting is configured
- `VestingReleased(asset, recipient, amount)`: emitted for each successful claim
