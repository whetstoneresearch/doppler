# TEST SHARED

Base contracts, fixtures, and utilities for test suite.

## WHERE TO LOOK

| Task | File | Notes |
|------|------|-------|
| Base unit tests | `BaseTest.sol` | DopplerConfig, buy/sell helpers, epoch navigation |
| Airlock fixtures | `DopplerFixtures.sol` | Full Airlock + modules setup |
| Fork testing | `ForkTest.sol`, `BaseForkTest.sol` | Network fork utilities |
| Hook configs | `HookConfigs.sol` | Hook flag configurations |
| Salt mining | `AirlockMiner.sol` | `mineV4()` for deterministic hook addresses |
| Custom router | `CustomRouter.sol` | Swap routing wrapper |
| Doppler impl | `DopplerImplementation.sol` | Test hook implementation |
| Slug vis | `SlugVis.sol` | Slug position visualization |
| Addresses | `Addresses.sol` | Network-specific addresses |

## KEY PATTERNS

### BaseTest Helpers

```solidity
// Buy/sell with exact in/out
buyExactIn(amount)   // Spend exact numeraire
buyExactOut(amount)  // Receive exact asset
sellExactIn(amount)  // Sell exact asset
sellExactOut(amount) // Receive exact numeraire

// Time navigation
goToEpoch(n)         // Jump to epoch n
goToNextEpoch()      // Advance one epoch
goToStartingTime()   // Jump to auction start
goToEndingTime()     // Jump past auction end

// Migration
prankAndMigrate()    // Prank as initializer, call migrate
```

### DopplerFixtures Setup

```solidity
_deployMockNumeraire()       // Deploy mock tokens
_deployAirlockAndModules()   // Full protocol setup
_airlockCreate(numeraire, isToken0)  // Create auction
_airlockCreateNative()       // ETH as numeraire
```

### Salt Mining (AirlockMiner)

Hook addresses must have correct flags. Use `mineV4()`:

```solidity
(bytes32 salt, address hook, address token) = mineV4(
    MineV4Params(airlock, manager, supply, toSell, numeraire, ...)
);
```

## ENV TOGGLES

Tests use `vm.envOr()` for scenario control without recompilation:

| Variable | Effect |
|----------|--------|
| `IS_TOKEN_0` | Asset is token0 (changes tick direction) |
| `USING_ETH` | Use native ETH as numeraire |
| `FEE` | Pool fee tier |
| `PROTOCOL_FEE` | V4 protocol fee |
| `V4_FEE` | Dynamic LP fee |

## CONVENTIONS

- Unit tests: `test/unit/` mirrors `src/` structure
- Invariant tests: `test/invariant/` with `fail_on_revert=true`
- Integration: `test/integration/` for E2E flows
- Use `vm.warp()` for time manipulation, not `skip()`
