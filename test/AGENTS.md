# test/ - Test Suite

## OVERVIEW

86+ test files across 4 categories. Foundry-based with shared fixtures.

## STRUCTURE

```
test/
├── unit/           # Isolated contract tests (mocked deps)
│   ├── doppler/    # Doppler.sol tests by function
│   ├── initializers/
│   ├── dopplerHooks/
│   ├── migrators/
│   ├── tokens/
│   ├── base/
│   └── governance/
├── invariant/      # Property-based fuzzing
├── integration/    # End-to-end with real deps
├── gas/            # Gas benchmarks
├── shared/         # Fixtures, utilities, base classes
└── utils/          # Custom revert decoder
```

## KEY FILES

| File | Purpose |
|------|---------|
| `shared/BaseTest.sol` | Base class for unit tests |
| `shared/BaseForkTest.sol` | Base class for fork tests |
| `shared/DopplerFixtures.sol` | Doppler deployment helpers |
| `shared/HookConfigs.sol` | Hook permission configs |
| `shared/Addresses.sol` | Deployed address constants |
| `invariant/DopplerHandler.sol` | Doppler invariant handler |
| `invariant/RehypeHandler.sol` | Rehype invariant handler |

## TEST CATEGORIES

### Unit (`test/unit/`)
- One test file per contract
- Mocked dependencies
- Pattern: `test/unit/<module>/<Contract>.t.sol`
- Example: `test/unit/doppler/AfterSwap.t.sol`

### Integration (`test/integration/`)
- Full system with real V4 pool manager
- Fork-based where needed
- Validates create -> migrate flows
- Example: `Rebalance.t.sol`, `RehypeDopplerHook.t.sol`

### Invariant (`test/invariant/`)
- Handlers define valid state transitions
- Default: 32 fuzz runs, depth 512
- Deep profile: 2048 runs
- Pattern: `<Contract>Handler.sol` + `<Contract>Invariants.t.sol`

### Gas (`test/gas/`)
- Benchmark key operations
- `V4Flow.gas.t.sol`

## ENV CONFIGURATION

Tests read from `.env` for scenario variation:
```bash
IS_TOKEN_0=TRUE|FALSE     # Token ordering
USING_ETH=TRUE|FALSE      # Native ETH vs WETH
V4_FEE=100                # Fee tier (bps)
```

## COMMANDS

```bash
forge test                          # All tests
forge test --mt test_swap           # Match test name
forge test --mc DopplerTest         # Match contract
forge test --mt invariant_          # Invariant tests only
FOUNDRY_PROFILE=deep forge test     # Deep fuzzing
```

## CONVENTIONS

- Test functions: `test_<action>_<condition>()`
- Fuzz inputs: `testFuzz_<action>(uint256 amount)`
- Revert tests: `test_<action>_RevertWhen_<condition>()`
- Setup in `setUp()`, not constructor
- Use `vm.expectRevert()` before failing calls
