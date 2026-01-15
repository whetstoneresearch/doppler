# Distribution Migrator

A wrapper migrator that distributes a configurable percentage of numeraire proceeds to a payout address before forwarding the remaining balances to an underlying liquidity migrator.

## Overview

The DistributionMigrator enables launch teams to receive a share of proceeds from token sales **without modifying the Airlock contract**. It acts as a middleware between Airlock and the actual liquidity migrator.

```
Airlock → DistributionMigrator → ForwardedUniswapV4Migrator → Uniswap V4 Pool
                    ↓
              Payout Address (receives % of numeraire)
```

## Contracts

| Contract | Description |
|----------|-------------|
| `DistributionMigrator.sol` | Main wrapper that handles distribution logic |
| `ForwardedUniswapV2Migrator.sol` | V2 migrator with airlock pointing to DistributionMigrator |
| `ForwardedUniswapV4Migrator.sol` | V4 migrator with airlock pointing to DistributionMigrator |

## Configuration

### Initialization Parameters

```solidity
(address payout, uint256 percentWad, address underlyingMigrator, bytes underlyingData)
```

| Parameter | Description | Constraints |
|-----------|-------------|-------------|
| `payout` | Address receiving distribution | Cannot be `address(0)` |
| `percentWad` | Distribution % in WAD (1e18 = 100%) | Max 50% (`5e17`) |
| `underlyingMigrator` | Forwarded migrator address | Must be whitelisted, must have `airlock == this` |
| `underlyingData` | Data forwarded to underlying `initialize()` | Format depends on underlying migrator |

### Percentage Examples

| Desired % | `percentWad` Value |
|-----------|-------------------|
| 1% | `1e16` |
| 5% | `5e16` |
| 10% | `1e17` |
| 25% | `25e16` |
| 50% (max) | `5e17` |

## Deployment Checklist

### 1. Deploy Contracts

```bash
# Deploy DistributionMigrator pointing to real Airlock
DistributionMigrator distributor = new DistributionMigrator(airlockAddress);

# Deploy ForwardedMigrator pointing to DistributionMigrator (NOT Airlock!)
ForwardedUniswapV4Migrator forwarded = new ForwardedUniswapV4Migrator(
    address(distributor),  // airlock = distributor
    poolManager,
    positionManager,
    locker,
    hook
);
```

### 2. Configure Locker (V4 only)

```solidity
// Approve the FORWARDED migrator in the locker
locker.approveMigrator(address(forwardedMigrator), true);
```

### 3. Deploy Hook with Correct Migrator (V4 only)

The hook MUST be deployed with `migrator = forwardedMigrator`:

```solidity
// When deploying hook
hook.setMigrator(address(forwardedMigrator));
```

### 4. Whitelist in Airlock

```solidity
// Whitelist BOTH the distributor AND the forwarded migrator
address[] memory modules = new address[](2);
modules[0] = address(distributor);
modules[1] = address(forwardedMigrator);

ModuleState[] memory states = new ModuleState[](2);
states[0] = ModuleState.LiquidityMigrator;
states[1] = ModuleState.LiquidityMigrator;

airlock.setModuleState(modules, states);
```

### 5. Validate Deployment

Run the validation script:

```bash
DISTRIBUTION_MIGRATOR=0x... \
FORWARDED_MIGRATOR=0x... \
AIRLOCK=0x... \
forge script script/ValidateDistributionMigrator.s.sol --rpc-url $RPC_URL
```

## Security Considerations

### Known Limitations

| Limitation | Risk | Mitigation |
|------------|------|------------|
| **ERC777 Tokens** | Reentrancy via `tokensReceived` hook | CEI pattern implemented; consider trusted payout addresses |
| **Fee-on-Transfer Tokens** | Underlying receives less than expected | Document limitation; tokens with fees not recommended |
| **Blocklisted Payout** | Transfer reverts if payout is blocklisted | Use non-blocklisted payout addresses |
| **Pausable Tokens** | Transfer reverts if token is paused | Monitor token status before migration |

### Access Control

| Function | Access | Notes |
|----------|--------|-------|
| `initialize()` | `onlyAirlock` | Called during `Airlock.create()` |
| `migrate()` | `onlyAirlock` | Called during `Airlock.migrate()` |
| `receive()` | `onlyAirlock` | Accepts ETH only from Airlock |
| `owner()` | Public view | Returns `airlock.owner()` |

### Invariants

1. **Distribution ≤ 50%**: `percentWad <= MAX_DISTRIBUTION_WAD`
2. **Balance Conservation**: `distribution + forwarded == original_balance`
3. **No Stuck Funds**: After `migrate()`, distributor has 0 balance
4. **Asset Untouched**: Distribution only affects numeraire, never asset

## Testing

```bash
# Run unit tests
forge test --match-contract DistributionMigratorTest -vvv

# Run with deep fuzzing
forge test --match-path "*distribution*" --fuzz-runs 10000 -v

# Run integration tests (requires fork)
forge test --match-contract DistributionMigratorV4 -vvv
```

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

## Errors

| Error | Cause |
|-------|-------|
| `InvalidPayout()` | Payout address is zero |
| `InvalidUnderlying()` | Underlying is zero or self |
| `InvalidPercent()` | Percent exceeds 50% |
| `AlreadyInitialized()` | Config exists for token pair |
| `PoolNotInitialized()` | No config for token pair |
| `AssetMismatch()` | Stored asset doesn't match tokens |
| `UnderlyingNotWhitelisted()` | Underlying not in Airlock whitelist |
| `UnderlyingNotForwarded()` | Underlying's airlock != this contract |
| `UnderlyingNotLockerApproved()` | V4 locker hasn't approved underlying |
| `UnderlyingHookMismatch()` | V4 hook's migrator != underlying |

## Specification

See [SPEC-distribution-migrator.md](../../../specs/SPEC-distribution-migrator.md) for the full specification.
