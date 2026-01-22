# DOPPLER PROTOCOL - AI AGENT KNOWLEDGE BASE

**Generated:** 2026-01-20  
**Commit:** 1c2d004  
**Branch:** dhook-migrator

## OVERVIEW

Liquidity bootstrapping protocol on Uniswap V4 using hooks. Implements epoch-based Dutch auctions (Doppler) with modular token deployment (Airlock).

## CRITICAL RULE

**IGNORE ALL UNISWAP V2 CODE** unless explicitly asked. V2 development is over. Files to skip:
- `src/UniswapV2Locker.sol`
- `src/migrators/UniswapV2Migrator.sol`
- `src/interfaces/IUniswapV2*.sol`
- Any test/script referencing V2

## STRUCTURE

```
doppler/
├── src/                    # Contracts (see src/AGENTS.md)
│   ├── initializers/       # Pool initializers, Doppler auction hook
│   ├── dopplerHooks/       # Swap-time hooks (Rehype, ScheduledLaunch)
│   ├── migrators/          # Liquidity migration modules
│   ├── tokens/             # Token factories (DERC20, CloneERC20)
│   ├── base/               # Base contracts (FeesManager, BaseHook)
│   ├── governance/         # Governance factories
│   ├── libraries/          # Math (Multicurve, TickLibrary)
│   ├── interfaces/         # Protocol interfaces
│   ├── types/              # Data structures
│   └── lens/               # View/quoter contracts
├── test/                   # Tests (see test/AGENTS.md)
├── script/                 # Deployment (see script/AGENTS.md)
├── deployments/            # Per-chain deployment logs + CLI
├── docs/                   # Protocol documentation
├── specs/                  # Implementation specifications
└── lib/                    # Git submodules (DO NOT MODIFY)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add new hook | `src/dopplerHooks/` | Extend `BaseDopplerHook` |
| New initializer | `src/initializers/` | Implement `IPoolInitializer` |
| New migrator | `src/migrators/` | Implement `ILiquidityMigrator` |
| Token variant | `src/tokens/` | Clone pattern preferred |
| Math/tick utils | `src/libraries/` | `Multicurve.sol` for curve math |
| Fee logic | `src/base/FeesManager.sol` | MasterChef-style distribution |
| Airlock orchestration | `src/Airlock.sol` | Module whitelist system |
| Integration test | `test/integration/` | Fork tests with real deps |
| Deploy to mainnet | `script/deployV4/` | V4-specific deployments |

## COMMANDS

```bash
# Setup
make install              # forge install

# Testing
make test                 # forge test --show-progress
make fuzz                 # invariant tests (32 runs)
make deep-fuzz            # invariant tests (2048 runs)

# Deployment
make deploy-v4-base       # Deploy V4 to Base mainnet
make deploy-v4-unichain   # Deploy V4 to Unichain mainnet
make generate-history     # Update deployment docs (bun CLI)

# Format
forge fmt                 # Format Solidity
forge fmt --check         # Check formatting
```

## BUILD SYSTEM

- **Foundry**: Solidity 0.8.26, EVM Cancun, `via_ir=true`, `optimizer_runs=0`
- **Bun**: TypeScript CLI for deployment history (`deployments/cli.ts`)
- **Python**: Visualization scripts (`scripts/plot_slugs.py`)

## CONVENTIONS

### Solidity Style
- Line length: 120 chars
- Bracket spacing: `{ x }` not `{x}`
- Int types: `uint256` not `uint`
- Sort imports alphabetically
- NatSpec on all public functions (`@notice`, `@dev`, `@param`, `@return`)

### Testing
- Unit tests: `test/unit/<module>/<Contract>.t.sol`
- Integration tests: `test/integration/<Flow>.t.sol`
- Invariant tests: `test/invariant/<Handler>.sol`
- Shared fixtures: `test/shared/`

### Naming
- Interfaces: `I<Name>.sol`
- Test files: `<Contract>.t.sol`
- Deploy scripts: `Deploy<Module>.s.sol`
- Errors: `<DescriptiveName>()` with no `Error` suffix

## ANTI-PATTERNS

- **NEVER** suppress type errors (`as any` equivalent patterns)
- **NEVER** use `@ts-ignore` in TypeScript CLI code
- **NEVER** modify `lib/` submodules directly
- **NEVER** commit `.env` files
- **NEVER** use V2 contracts for new features

## MODULE SYSTEM

Airlock uses whitelisted modules with state machine:
```
NotWhitelisted -> TokenFactory | GovernanceFactory | PoolInitializer | LiquidityMigrator
```

Modules must be whitelisted via `setModuleState()` before `create()` can use them.

## DEPENDENCIES

Key submodules (in `lib/`):
- `v4-core`: Uniswap V4 pool manager, hooks
- `v4-periphery`: BaseHook, periphery contracts
- `solady`: Gas-optimized ERC20, math
- `forge-std`: Testing utilities

## NETWORKS

Mainnets: Base (8453), Unichain (130), Ink (57073), Monad (143)  
Testnets: Base Sepolia, Unichain Sepolia, Ink Sepolia, Monad Testnet

## GOTCHAS

1. **Hook address validation**: V4 hooks must have specific address bits set. Use `HookMiner` in tests.
2. **via_ir builds**: Slow compilation. CI uses `--via-ir` flag explicitly.
3. **Test env vars**: `.env` controls `IS_TOKEN_0`, `USING_ETH`, `V4_FEE` for scenario testing.
4. **No profile.ci**: `foundry.toml` lacks `[profile.ci]`; CI uses default profile.
5. **Multicurve complexity**: `Multicurve.sol` is 12k+ lines; prefer using existing helpers.
