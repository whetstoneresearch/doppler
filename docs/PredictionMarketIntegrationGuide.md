# Prediction Market Integration Guide

This guide describes how to integrate prediction markets with `Airlock` using `PredictionMigrator`.

## Overview

The prediction market flow has 3 stages:

1. `create`: register each market entry (`token`) with `(oracle, entryId)` in `PredictionMigrator`.
2. `migrate`: move proceeds into the market pot after oracle finalization.
3. `claim`: winning token holders claim pro-rata numeraire.

Reference implementation:
- `src/migrators/PredictionMigrator.sol`
- `test/integration/PredictionMarket.t.sol`

## Required Components

- `Airlock`
- `PredictionMigrator` as a whitelisted `LiquidityMigrator` module
- Token factory that creates burnable entry tokens (`burn(uint256)` required)
- Pool initializer (`DopplerHookInitializer` in current integration)
- Prediction oracle implementing `IPredictionOracle`
- Optional governance factory (`NoOpGovernanceFactory` is commonly used)

## Critical Integration Requirements

- Entry tokens must support `burn(uint256)`.
  - If burn is unavailable/restricted, `migrate` reverts.
- A market is keyed by `oracle` and has exactly one numeraire.
  - First entry sets numeraire; later entries for same oracle must match.
- `migrate` expects exactly one registered entry token in `(token0, token1)`.
  - Both registered or neither registered reverts.
- Oracle must be finalized before migration and before first successful claim.

## Step-By-Step Integration

### 1) Deploy and Whitelist Modules

Deploy `PredictionMigrator(airlock)` and whitelist it with:

```solidity
address[] memory modules = new address[](1);
modules[0] = address(predictionMigrator);
ModuleState[] memory states = new ModuleState[](1);
states[0] = ModuleState.LiquidityMigrator;
airlock.setModuleState(modules, states);
```

For the hook-based flow, deploy and register `NoSellDopplerHook` on `DopplerHookInitializer`.

### 2) Create Each Entry

For each market entry token, call `airlock.create` with:

- `liquidityMigrator = predictionMigrator`
- `liquidityMigratorData = abi.encode(oracle, entryId)`
- shared market numeraire for all entries under the same `oracle`

Example:

```solidity
CreateParams memory params = CreateParams({
    initialSupply: 1_000_000 ether,
    numTokensToSell: 1_000_000 ether,
    numeraire: numeraire,
    tokenFactory: tokenFactory,
    tokenFactoryData: tokenFactoryData,
    governanceFactory: governanceFactory,
    governanceFactoryData: governanceFactoryData,
    poolInitializer: dopplerInitializer,
    poolInitializerData: poolInitializerData,
    liquidityMigrator: predictionMigrator,
    liquidityMigratorData: abi.encode(address(oracle), entryId),
    integrator: address(0),
    salt: salt
});
```

During `create`, `PredictionMigrator.initialize` stores:
- token -> oracle mapping
- `(oracle, token) -> entryId`
- entry state (unmigrated)

### 3) Finalize the Oracle

Before migration, oracle must return `(winner, isFinalized=true)` from:

```solidity
getWinner(address oracle) returns (address winningToken, bool isFinalized)
```

### 4) Migrate Each Entry

Call `airlock.migrate(entryToken)` per entry after graduation/finalization conditions are met.

`PredictionMigrator.migrate`:
- validates pair has exactly one registered entry token
- checks oracle finalization
- checks pair numeraire matches market numeraire
- computes proceeds delta using global per-numeraire accounting
- computes `claimableSupply = totalSupply - unsoldBalance`
- burns unsold entry tokens
- updates entry contribution and market pot

### 5) Claim Winnings

Users claim with winning tokens:

1. approve winning token to `PredictionMigrator`
2. optionally `previewClaim(oracle, tokenAmount)`
3. call `claim(oracle, tokenAmount)`

Payout math:

```text
claimAmount = mulDiv(tokenAmount, market.totalPot, winningEntry.claimableSupply)
```

## Shared-Numeraire Accounting Model

`PredictionMigrator` tracks a global per-numeraire accounted balance:

- migration contribution = `currentBalance(numeraire) - accounted[numeraire]`
- after migration: `accounted[numeraire] = currentBalance`
- on claim payout: `accounted[numeraire] -= claimAmount`

This prevents cross-market contamination when multiple markets share the same numeraire.

## Common Reverts and Meaning

- `EntryNotRegistered`: token pair does not include a registered entry
- `InvalidTokenPair`: both tokens (or ambiguous pair) are registered entries
- `NumeraireMismatch`: entry migrated with wrong quote token
- `OracleNotFinalized`: oracle is not finalized yet
- `AlreadyMigrated`: entry already migrated
- `WinningEntryNotMigrated`: claim attempted before winning entry migration
- `AccountingInvariant`: unexpected external balance drift vs accounted state

## Test Checklist

Run these before production:

```bash
forge test --match-path test/unit/migrators/PredictionMigrator.t.sol
forge test --match-path test/integration/PredictionMarket.t.sol
forge test --match-path test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol
forge test --match-path test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol
FOUNDRY_PROFILE=deep forge test --match-path test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol
FOUNDRY_PROFILE=deep forge test --match-path test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol
```
