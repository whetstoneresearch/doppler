# src/ - Contract Source

## OVERVIEW

58 Solidity contracts implementing Doppler protocol. Core architecture: Airlock (orchestrator) + modular factories + V4 hooks.

## DIRECTORY MAP

| Directory | Purpose | Key Files |
|-----------|---------|-----------|
| `initializers/` | Pool setup + Doppler auction | `Doppler.sol`, `DopplerHookInitializer.sol`, `UniswapV4MulticurveInitializer.sol` |
| `dopplerHooks/` | Swap-time hooks | `RehypeDopplerHook.sol`, `ScheduledLaunchDopplerHook.sol` |
| `migrators/` | Post-auction migration | `UniswapV4Migrator.sol`, `UniswapV4MulticurveMigrator.sol` |
| `tokens/` | Token factories | `DERC20.sol`, `CloneERC20.sol`, `TokenFactory.sol` |
| `base/` | Shared base contracts | `FeesManager.sol`, `BaseHook.sol`, `BaseDopplerHook.sol` |
| `governance/` | Governance factories | `GovernanceFactory.sol`, `NoOpGovernanceFactory.sol` |
| `libraries/` | Math utilities | `Multicurve.sol`, `TickLibrary.sol`, `MigrationMath.sol` |
| `interfaces/` | Protocol interfaces | `IPoolInitializer.sol`, `ILiquidityMigrator.sol`, `IDopplerHook.sol` |
| `types/` | Data structures | `Position.sol`, `BeneficiaryData.sol`, `RehypeTypes.sol` |
| `lens/` | View contracts | `DopplerLens.sol` |

## CORE CONTRACTS

### Airlock.sol (Root)
- Main orchestrator for token launches
- Module whitelist: `setModuleState(address, ModuleState)`
- Entry point: `create(CreateParams)` -> deploys token + governance + pool
- Migration: `migrate(asset)` -> exits liquidity, calls migrator

### Doppler.sol (initializers/)
- Uniswap V4 hook implementing Dutch auction
- Epoch-based rebalancing with tick accumulator
- Slugs: lower (sell-back), upper (purchase), price discovery
- ~1200 lines, highly complex

### DopplerHookInitializer.sol (initializers/)
- Factory for deploying hooked V4 pools
- Supports swap-time Doppler hooks (Rehype, etc.)
- Virtual migration via `graduate(asset)`
- Status flow: `Uninitialized -> Initialized -> Locked -> Graduated | Exited`

## INHERITANCE PATTERNS

```
BaseHook (v4-periphery)
    └── BaseDopplerHook
            ├── RehypeDopplerHook
            ├── ScheduledLaunchDopplerHook
            └── SwapRestrictorDopplerHook

IPoolInitializer
    ├── UniswapV3Initializer
    ├── UniswapV4Initializer (uses Doppler)
    ├── UniswapV4MulticurveInitializer
    └── DopplerHookInitializer

ILiquidityMigrator
    ├── UniswapV4Migrator
    ├── UniswapV4MulticurveMigrator
    └── NoOpMigrator

FeesManager (abstract)
    ├── UniswapV4MulticurveInitializer
    └── DopplerHookInitializer
```

## CONVENTIONS

- All public functions have NatSpec
- Custom errors preferred over require strings
- `onlyAirlock` modifier for module entry points
- `onlyPoolManager` for V4 hook callbacks
- Position data uses `Position` struct from `types/Position.sol`

## SKIP (V2 DEPRECATED)

- `UniswapV2Locker.sol`
- `UniswapV2Migrator.sol`
- `interfaces/IUniswapV2*.sol`
