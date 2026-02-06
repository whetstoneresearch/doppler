# Doppler Prediction Markets High-Level Spec (v1.0.1)

## 1. Purpose

Define the high-level behavior and integration requirements for prediction markets built on Doppler + Airlock using `PredictionMigrator`.

This spec captures the production posture after:

- global per-numeraire accounting hardening
- strict burnable-asset migration requirement
- invariant harness expansion (ERC20 and ETH numeraires)

## 2. Scope

In scope:

- market entry registration at `create`
- proceeds migration at `migrate`
- winner claims
- multi-market shared-numeraire correctness

Out of scope:

- oracle design details beyond `IPredictionOracle` surface
- front-end UX implementation details
- non-Doppler auction mechanics

## 3. Architecture

Core contracts:

- `Airlock` orchestrates create/migrate lifecycle and module dispatch
- `PredictionMigrator` tracks entries, pots, claims, and payout accounting
- `IPredictionOracle` reports winner + finalization state
- Doppler hook stack (including `NoSellDopplerHook`) constrains market behavior

Market identity:

- A market is keyed by `oracle` address.
- Each market contains one or more entries (`entryId`, token pairs).
- All entries in a market must share a single numeraire.

## 4. Lifecycle

### 4.1 Create / Initialize

For each entry creation:

1. Airlock calls `PredictionMigrator.initialize(asset, numeraire, abi.encode(oracle, entryId))`.
2. Migrator enforces uniqueness:
   - `(oracle, asset)` must not already map to an entry
   - `(oracle, entryId)` must be unused
3. First entry sets market numeraire; later entries must match.
4. Entry is registered but not migrated.

### 4.2 Migrate

When Airlock migrates an entry:

1. Pair validation: exactly one token in `(token0, token1)` must be a registered entry token.
2. Oracle must be finalized.
3. Pair numeraire must match market numeraire.
4. Contribution is inferred via global per-numeraire balance delta:
   - `delta = currentBalance(numeraire) - accounted[numeraire]`
   - `accounted[numeraire] = currentBalance(numeraire)`
5. Unsold entry tokens are removed via strict `burn(assetBalance)`.
6. Entry and market accounting updates:
   - `entry.contribution += delta` (single migration per entry in current model)
   - `entry.claimableSupply = totalSupply - unsold`
   - `entry.isMigrated = true`
   - `market.totalPot += delta`

### 4.3 Claim

For winning token holders:

1. Market resolves lazily on first claim if not cached:
   - fetch winner from oracle
   - require finalized
2. Winning entry must already be migrated.
3. Claim payout:
   - `claimAmount = mulDiv(tokenAmount, market.totalPot, winningEntry.claimableSupply)`
4. Winning tokens are transferred from claimer to migrator.
5. Accounting updates before payout transfer:
   - `market.totalClaimed += claimAmount`
   - `accounted[numeraire] -= claimAmount`
6. Numeraire is transferred to claimer.

## 5. Security and Correctness Properties

1. Shared-numeraire isolation:
   - migrations in market A do not contaminate market B contributions.
2. Claim/migrate interleaving safety:
   - claims between migrations preserve correct later migration deltas.
3. Pair-shape safety:
   - both-registered and neither-registered pair shapes revert.
4. Numeraire consistency:
   - market-level numeraire cannot drift across entries.
5. Burnability enforcement:
   - non-burnable entry tokens are unsupported and migration reverts.
6. Reentrancy hardening:
   - `claim` is protected by `ReentrancyGuard`.

## 6. Integration Requirements

Required:

- whitelist `PredictionMigrator` as a `LiquidityMigrator` module in Airlock
- use burnable entry tokens implementing `burn(uint256)`
- ensure all entries under one oracle use same numeraire
- ensure oracle finalization semantics are trustworthy

Recommended:

- keep sell paths disabled with `NoSellDopplerHook` where applicable
- surface claim timing UX warning:
  - claiming before all entries migrate can produce lower payout than waiting

## 7. Error Surface (High Level)

- `EntryAlreadyExists`
- `EntryIdAlreadyUsed`
- `EntryNotRegistered`
- `InvalidTokenPair`
- `NumeraireMismatch`
- `OracleNotFinalized`
- `AlreadyMigrated`
- `WinningEntryNotMigrated`
- `AccountingInvariant`

## 8. Verification Strategy

Production gating test stack:

- unit: `test/unit/migrators/PredictionMigrator.t.sol`
- integration: `test/integration/PredictionMarket.t.sol`
- invariants (ERC20): `test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol`
- invariants (ETH): `test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol`
- deep invariant profile (`FOUNDRY_PROFILE=deep`) for both invariant suites

Invariant themes:

- on-chain market/entry state matches ghost state
- global migrator numeraire balance equals net contributed minus claimed
- global ghost sums equal sum of per-market ghosts

## 9. References

- Implementation: `src/migrators/PredictionMigrator.sol`
- Interface: `src/interfaces/IPredictionMigrator.sol`
- Integration guide: `docs/PredictionMarketIntegrationGuide.md`
- Invariant harness spec: `specs/prediction-migrator-invariant-harness-spec.md`
