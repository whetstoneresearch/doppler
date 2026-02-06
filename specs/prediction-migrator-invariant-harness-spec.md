# PredictionMigrator Invariant Harness Spec

## Goal

Provide a reusable invariant-testing harness for `PredictionMigrator` that stress-tests multi-market accounting with a shared numeraire under arbitrary migrate/claim/transfer action sequences.

This spec is intended for agents extending the harness before production.

## Files

- `test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorEthInvariantHandler.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorMultiEntryInvariantHandler.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorMultiEntryInvariants.t.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorMultiEntryEthInvariantHandler.sol`
- `test/invariant/PredictionMigrator/PredictionMigratorMultiEntryEthInvariants.t.sol`

## Harness Architecture

### Core Components

1. `PredictionMigratorAirlockHarness`
- Minimal wrapper that is set as `airlock` for `PredictionMigrator`.
- Exposes `initialize()` and `migrate()` passthroughs so handler actions can trigger `onlyAirlock` code paths.

2. `InvariantPredictionERC20`
- Minimal ERC20 for invariant tests (mint + burn included).
- Used for entry tokens and shared numeraire.

3. `PredictionMigratorInvariantHandlerBase`
- Shared abstract handler with reusable ghost state and common actions (`claim*`, token transfers).
- Exposes helper methods for bounded migration amount and consistent ghost updates.
- Only migration funding logic is variant-specific.

4. `PredictionMigratorInvariantHandler`
- ERC20-numeraire implementation of the shared base.
- Owns large ERC20 numeraire balance used to fund migrations.

5. `PredictionMigratorInvariantsTest`
- Deploys two independent markets (`oracleA`, `oracleB`) sharing one numeraire.
- Registers one entry per market and finalizes both oracles.
- Configures target selectors and invariant assertions.

6. `PredictionMigratorEthInvariantHandler` + `PredictionMigratorEthInvariantsTest`
- ETH-numeraire implementation of the same shared handler base (`address(0)` numeraire).
- Migrations fund `PredictionMigrator` via direct ETH transfer before `migrate()`.

7. `PredictionMigratorMultiEntryInvariantHandler` + `PredictionMigratorMultiEntryInvariantsTest`
- ERC20-numeraire multi-entry scenario with two entries per market (winner + loser).
- Adds loser migration and loser transfer selectors.
- Adds per-market "pot equals sum of entry contributions" invariant.

8. `PredictionMigratorMultiEntryEthInvariantHandler` + `PredictionMigratorMultiEntryEthInvariantsTest`
- ETH-numeraire variant of the multi-entry scenario.
- Mirrors multi-entry invariants for native ETH accounting.

## Scenario Model

- Shared numeraire across multiple markets.
- One winning entry token per market.
- Entry supply held entirely by users (`alice`, `bob`) so migration has zero unsold tokens.
- Claims can happen between migrations across markets.

This specifically targets the contamination class fixed by global per-numeraire accounting.

### Active Variants

1. ERC20 numeraire base variant:
- `PredictionMigratorInvariants.t.sol`
- Global balance invariant uses `IERC20(numeraire).balanceOf(migrator)`.

2. ETH numeraire base variant:
- `PredictionMigratorEthInvariants.t.sol`
- Global balance invariant uses `address(migrator).balance`.

3. ERC20 numeraire multi-entry variant:
- `PredictionMigratorMultiEntryInvariants.t.sol`
- Two entries per market (winner + loser), shared numeraire.

4. ETH numeraire multi-entry variant:
- `PredictionMigratorMultiEntryEthInvariants.t.sol`
- Two entries per market (winner + loser), ETH numeraire.

## Handler Actions

- `migrateOracleA(uint128 amountSeed, uint8 orderingSeed)`
- `migrateOracleB(uint128 amountSeed, uint8 orderingSeed)`
- `claimOracleA(uint128 amountSeed, uint8 actorSeed)`
- `claimOracleB(uint128 amountSeed, uint8 actorSeed)`
- `transferOracleATokens(uint128 amountSeed, uint8 fromSeed)`
- `transferOracleBTokens(uint128 amountSeed, uint8 fromSeed)`

Multi-entry handlers add:

- `migrateWinnerOracleA(uint128 amountSeed, uint8 orderingSeed)`
- `migrateLoserOracleA(uint128 amountSeed, uint8 orderingSeed)`
- `migrateWinnerOracleB(uint128 amountSeed, uint8 orderingSeed)`
- `migrateLoserOracleB(uint128 amountSeed, uint8 orderingSeed)`
- `transferWinnerOracleATokens(uint128 amountSeed, uint8 fromSeed)`
- `transferLoserOracleATokens(uint128 amountSeed, uint8 fromSeed)`
- `transferWinnerOracleBTokens(uint128 amountSeed, uint8 fromSeed)`
- `transferLoserOracleBTokens(uint128 amountSeed, uint8 fromSeed)`

### Action Safety Rules

- Handler actions must not revert (`foundry.toml` sets `invariant.fail_on_revert = true`).
- Every action must be preconditioned/bounded:
  - Skip if entry already migrated.
  - Skip claim if entry not migrated.
  - Bound claim amount by holder balance.
  - Bound migration amount by configured max.

## Ghost State

- `ghost_totalContributed`
- `ghost_totalClaimed`
- `ghost_marketPot[oracle]`
- `ghost_marketClaimed[oracle]`
- `ghost_entryMigrated[oracle][entryId]`
- `ghost_entryContribution[oracle][entryId]`

Ghost state is updated only after successful action execution.

## Invariants

1. Market + entry accounting mirrors ghost state.
- `market.totalPot == ghost_marketPot[oracle]`
- `market.totalClaimed == ghost_marketClaimed[oracle]`
- `entry.contribution == ghost_entryContribution[oracle][entryId]`
- `entry.isMigrated == ghost_entryMigrated[oracle][entryId]`
- `market.totalClaimed <= market.totalPot`

2. Global migrator numeraire balance equals net flow.
- `numeraire.balanceOf(migrator) == ghost_totalContributed - ghost_totalClaimed`

3. Global ghost totals equal per-market ghost sums.
- `ghost_totalContributed == sum(ghost_marketPot)`
- `ghost_totalClaimed == sum(ghost_marketClaimed)`

4. Claimable supply shape for this harness scenario.
- Migrated entry: `claimableSupply == ENTRY_SUPPLY`
- Unmigrated entry: `claimableSupply == 0`

5. Differential claim payout check (in handler action path).
- Claimer-observed payout delta matches `previewClaim(...)` before claim.

6. Multi-entry pot aggregation check.
- `market.totalPot == sum(entry.contribution for all entries in market)`

## How to Run

- Standard:
```bash
forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol
```

- Standard (ETH variant):
```bash
forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol
```

- Deep profile:
```bash
FOUNDRY_PROFILE=deep forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorInvariants.t.sol
```

- Deep profile (ETH variant):
```bash
FOUNDRY_PROFILE=deep forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorEthInvariants.t.sol
```

- Standard (multi-entry ERC20 variant):
```bash
forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorMultiEntryInvariants.t.sol
```

- Standard (multi-entry ETH variant):
```bash
forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorMultiEntryEthInvariants.t.sol
```

- Deep profile (multi-entry ERC20 variant):
```bash
FOUNDRY_PROFILE=deep forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorMultiEntryInvariants.t.sol
```

- Deep profile (multi-entry ETH variant):
```bash
FOUNDRY_PROFILE=deep forge test --offline --match-path test/invariant/PredictionMigrator/PredictionMigratorMultiEntryEthInvariants.t.sol
```

## Extension Guide For Agents

When adding actions/invariants:

1. Keep changes additive; do not remove existing invariants.
2. Preserve non-reverting handler behavior.
3. Put shared behavior in `PredictionMigratorInvariantHandlerBase`; keep only numeraire-specific migration logic in concrete handlers.
4. Add any new action selector to `targetSelector(...)`.
5. Update ghost state in the same transaction path as the state-changing action.
6. Prefer invariant formulas over example assertions.
7. If scenario assumptions change (e.g., non-zero unsold), update the claimable-supply invariant accordingly.

## Completed Additions

1. Multi-entry-per-market scenario.
- Added winner/loser entries per market in both ERC20 and ETH variants.
- Added loser migration and loser transfer selectors.
- Added per-market pot aggregation invariants.
- Validated with standard and deep invariant runs (zero reverts).

2. Differential claim-payout invariant.
- Handler action path now checks claimer-observed payout delta against `previewClaim(...)`.
- Applied in both ERC20 and ETH multi-entry variants.
- Validated across deep runs.

## Next Steps

1. Add a non-zero-unsold migration variant.
- Add a dedicated invariant setup where migrator receives unsold tokens before `migrate`.
- Verify `claimableSupply` follows `totalSupply - unsold` for migrated entries.
- Keep the strict burnability assumption (this variant should only use burnable test tokens).
- Exit criteria: invariants remain non-reverting and claimable-supply assertions hold.

2. Add selector-weight tuning and reporting.
- Bias action selection to increase claim-between-migrations and cross-market interleavings.
- Record selector call counts in run artifacts and verify meaningful coverage of each action.
- Exit criteria: each selector is exercised at high volume in deep runs.

3. Add CI production gate commands.
- Add/update CI steps for both standard and `FOUNDRY_PROFILE=deep` invariant runs (ERC20 + ETH suites).
- Fail CI on any invariant revert or failure.
- Exit criteria: all invariant suites are required checks before release tagging.
