# Distribution Migrator Specification

## Summary
The **DistributionMigrator** is a whitelisted `ILiquidityMigrator` module called by **Airlock** during `create()` and `migrate()`.

It:
1. **initializes** and **stores** a per-(asset,numeraire) distribution configuration,
2. on migration, **pays a configurable % of the *numeraire proceeds*** to a payout address,
3. then **forwards the remaining balances** to an **underlying liquidity migrator** to create the destination liquidity.

This is intended to enable launch teams to receive a share of proceeds **without modifying Airlock**.

---

## Core design constraints

### Airlock is unchanged
- **Airlock must not be modified.**
- Airlock continues to:
  - call `liquidityMigrator.initialize(asset, numeraire, data)` during `create()`,
  - later transfer post-fee proceeds to the migrator,
  - then call `liquidityMigrator.migrate(sqrtPriceX96, token0, token1, timelock)`.

### Forwarded-underlying migrators (required)
Because existing migrators use `onlyAirlock` (from `ImmutableAirlock`) on `initialize()` and `migrate()`, the wrapper cannot call them directly.

Therefore, **the underlying migrator used with DistributionMigrator MUST be a “forwarded” migrator** whose `ImmutableAirlock.airlock` is set to the **DistributionMigrator address**, not the real Airlock.

In other words:
- real Airlock → calls DistributionMigrator
- DistributionMigrator → calls forwarded underlying migrator
- forwarded underlying migrator → treats DistributionMigrator as its `airlock` for `onlyAirlock`

### Fail-fast requirement
Misconfiguration that would predictably cause migration failure **must revert during `initialize()`**, not during `migrate()`.

This is achieved by:
- performing strong, explicit validation in `DistributionMigrator.initialize()`, and
- calling `underlying.initialize(...)` during wrapper initialize so the underlying migrator’s own validation also runs at create-time.

> Note: conditions that depend on future auction outcomes (e.g., the final `sqrtPriceX96` or future balances) cannot be fully prevalidated.

---

## Supported underlying migrators

This wrapper is designed to support **forwarded variants** of:
- ✅ UniswapV2Migrator
- ✅ UniswapV4Migrator
- ✅ UniswapV4MulticurveMigrator
- ❌ PredictionMigrator (explicitly out of scope)

### Additional requirements for forwarded Uniswap V4 migrators
The existing V4 migrators call `airlock.owner()` / `Airlock(airlock).owner()`.

Since the forwarded migrators will have `airlock == DistributionMigrator`, the **DistributionMigrator MUST implement**:

```solidity
function owner() external view returns (address);
```

and it MUST return the **real Airlock owner**, i.e. `return airlock.owner();`.

### Hook binding requirement (V4)
V4 migrator hooks restrict initialization to a specific migrator address.

When deploying a forwarded V4 migrator, its hook MUST be deployed/configured so that:
- `hook.migrator() == address(forwardedMigrator)`

Otherwise the underlying migrator will revert at migration-time.

### Locker approval requirement (V4)
Both `StreamableFeesLocker` and `StreamableFeesLockerV2` require the migrator to be approved.

When using a forwarded V4 migrator, the locker MUST have:
- `approvedMigrators[address(forwardedMigrator)] == true`

Otherwise the underlying migrator will revert at migration-time.

---

## DistributionMigrator interface

Implements `ILiquidityMigrator` and inherits `ImmutableAirlock` (pointing to the **real Airlock**).

```solidity
function initialize(address asset, address numeraire, bytes calldata data)
    external
    returns (address migrationPool);

function migrate(uint160 sqrtPriceX96, address token0, address token1, address recipient)
    external
    payable
    returns (uint256 liquidity);

// Required for forwarded V4 migrators:
function owner() external view returns (address);
```

### Receiving ETH
Airlock transfers ETH proceeds to the migrator via a plain ETH transfer.

DistributionMigrator MUST implement:
- `receive() external payable` and it SHOULD be restricted to `onlyAirlock`.

---

## Initialization payload

`DistributionMigrator.initialize(asset, numeraire, data)` expects:

```solidity
(address payout, uint256 percentWad, address underlyingMigrator, bytes underlyingData)
```

- `underlyingData` is **forwarded** to the underlying migrator’s `initialize()`.
- `underlyingData` is **NOT stored onchain** by DistributionMigrator.

---

## Constants

- `WAD = 1e18`
- `MAX_DISTRIBUTION_WAD = 5e17` (50%)

---

## Storage

DistributionMigrator stores per-pair configuration keyed by the sorted pair `(token0, token1)` where:
- `(token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset)`

```solidity
struct DistributionConfig {
  address payout;
  uint256 percentWad;
  ILiquidityMigrator underlying;
  address asset; // used to identify the numeraire at migrate-time
}

mapping(address token0 => mapping(address token1 => DistributionConfig))
    public getDistributionConfig;
```

### Overwrites are forbidden
If configuration already exists for `(token0, token1)`, `initialize()` MUST revert.

---

## Validation in initialize() (fail-fast)

Given `asset`, `numeraire`, and decoded `(payout, percentWad, underlyingMigrator, underlyingData)`:

### Basic checks
- `payout != address(0)`
- `underlyingMigrator != address(0)`
- `underlyingMigrator != address(this)`
- `percentWad <= MAX_DISTRIBUTION_WAD`

### No overwrites
- Compute `(token0, token1)` from `(asset, numeraire)`.
- If `getDistributionConfig[token0][token1].payout != address(0)` then revert.

### Underlying is a whitelisted Airlock module
- `airlock.getModuleState(underlyingMigrator) == ModuleState.LiquidityMigrator` MUST hold.

### Underlying is correctly forwarded to this DistributionMigrator
To prevent a late failure due to `onlyAirlock`, DistributionMigrator MUST verify:
- `IHasAirlock(underlyingMigrator).airlock() == address(this)`

Where `IHasAirlock` is:
```solidity
interface IHasAirlock { function airlock() external view returns (address); }
```

### Hook + locker preflight checks (V4)
If the underlying migrator exposes these accessors, DistributionMigrator SHOULD preflight:
- `locker.approvedMigrators(underlyingMigrator) == true`
- `hook.migrator() == underlyingMigrator`

These checks exist specifically to satisfy the fail-fast requirement.

### Persist config
Store `DistributionConfig({ payout, percentWad, underlying, asset })` at `(token0, token1)`.

### Forward initialize
Call:
- `migrationPool = underlying.initialize(asset, numeraire, underlyingData)`

and return it.

Any revert from `underlying.initialize()` MUST bubble up (do not swallow).

---

## Distribution behavior

### Scope
- Distribution applies **only** to **numeraire** balances.
- Asset balances are untouched.

### Formula
- `distribution = floor(numeraireBalance * percentWad / WAD)`

### Rounding
- Round **down**.
- Any remainder stays in the migrator and is used for liquidity.

---

## migrate() behavior

### Preconditions
- callable only by Airlock (same pattern as other migrators)
- look up `config = getDistributionConfig[token0][token1]`
- if missing, revert `PoolNotInitialized()`

### Identify numeraire
Using stored `config.asset`:
- if `config.asset == token0` then `numeraire = token1`
- else if `config.asset == token1` then `numeraire = token0`
- else revert `AssetMismatch()` (should never happen if initialize was correct)

### Pay distribution
- compute `numeraireBalance`:
  - if `numeraire == address(0)`: `address(this).balance`
  - else: `ERC20(numeraire).balanceOf(address(this))`
- compute `distribution`
- transfer `distribution` to `config.payout`:
  - ETH via `safeTransferETH`
  - ERC20 via `safeTransfer`

### Forward balances to underlying
Forward the entire remaining balances of `token0` and `token1` to `config.underlying`:
- If `token0 != address(0)`: transfer full `ERC20(token0).balanceOf(address(this))` to underlying.
- Always transfer full `ERC20(token1).balanceOf(address(this))` to underlying.

### Forward ETH to underlying (if needed)
If `token0 == address(0)` (i.e., one side is ETH), call the underlying migrator with:
- `value = address(this).balance` (remaining ETH after payout)

### Call underlying migrate
Call:
- `liquidity = underlying.migrate{value: maybeETH}(sqrtPriceX96, token0, token1, recipient)`

Any revert from `underlying.migrate()` MUST bubble up.

### Optional cleanup
Optionally delete config after successful migrate to reduce storage:
- `delete getDistributionConfig[token0][token1];`

---

## Events

```solidity
event Distribution(
  address indexed payout,
  address indexed numeraire,
  uint256 amount,
  uint256 percentWad
);

event WrappedMigration(
  address indexed underlying,
  address indexed token0,
  address indexed token1,
  uint160 sqrtPriceX96
);
```

---

## Errors

Required:
- `InvalidPayout()`
- `InvalidUnderlying()`
- `InvalidPercent()`
- `AlreadyInitialized()`
- `PoolNotInitialized()`
- `AssetMismatch()`

Recommended:
- `UnderlyingNotWhitelisted()`
- `UnderlyingNotForwarded()`
- `UnderlyingNotLockerApproved()`
- `UnderlyingHookMismatch()`

---

## Test plan

### Unit tests
- `initialize()`:
  - validates payload (payout, percent, underlying)
  - rejects overwrites
  - checks underlying is whitelisted
  - checks underlying is forwarded to distributor (`underlying.airlock() == distributor`)
  - forwards `underlyingData` and bubbles underlying revert reasons

- `migrate()`:
  - distributes only numeraire
  - does not touch asset balances except forwarding to underlying
  - rounding is floor
  - ETH-numeraire path pays payout and forwards remaining ETH as `msg.value`
  - bubbles underlying revert reasons (no try/catch)

### Integration tests
- Airlock create + migrate using:
  - DistributionMigrator → ForwardedUniswapV2Migrator
  - DistributionMigrator → ForwardedUniswapV4Migrator
  - DistributionMigrator → ForwardedUniswapV4MulticurveMigrator

- V4-specific integration:
  - forwarded migrator is approved in correct locker
  - hook migrator binding is correct
  - DistributionMigrator.owner() returns real Airlock owner
