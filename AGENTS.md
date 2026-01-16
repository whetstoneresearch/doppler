# AGENTS.md - Doppler Protocol

> Guidelines for AI agents and contributors working in this repository.

## Project Overview

Doppler is a Solidity protocol built on Uniswap v4 hooks. Uses Foundry for building, testing, and deployment. TypeScript (Bun) scripts handle deployment logs.

**Important**: Active development focuses on Uniswap v4. Ignore v2-related files, contracts, and issues unless explicitly asked.

---

## Build Commands

```bash
# Install dependencies
make install
# or: forge install

# Build contracts
forge build

# Build with IR and sizes (CI default)
forge build --via-ir --sizes
```

---

## Test Commands

```bash
# Run all tests
make test
# or: forge test --show-progress

# Run with verbose output
forge test -vvv

# Run with via-ir (CI default)
forge test -vvv --via-ir

# Run invariant/fuzz tests only
make fuzz
# or: forge test --mt invariant_ --show-progress

# Extended fuzz testing (2048 runs)
make deep-fuzz
# or: FOUNDRY_PROFILE=deep forge test --mt invariant_ --show-progress

# Coverage report
make coverage
# or: forge coverage --ir-minimum --report lcov
```

### Running a Single Test

```bash
# By test name
forge test --match-test testMyFunction -vvv

# By contract name
forge test --match-contract MyContractTest -vvv

# By file path pattern
forge test --match-path "**/test/unit/MyTest.t.sol" -vvv

# With gas report
forge test --match-contract MyContractTest --gas-report

# Debug mode
forge test --match-test testMyFunction -vvvv --debug
```

### Test Organization

Tests live in three folders:
- `test/unit/` — Unit and fuzz tests, minimal setup, mocked dependencies
- `test/invariant/` — Invariant tests with real dependencies
- `test/integration/` — End-to-end tests for create/migrate flows

---

## Lint & Format

```bash
# Auto-format all Solidity
forge fmt

# Check formatting (CI uses this)
forge fmt --check
```

---

## Code Style

### Formatting Rules (from foundry.toml)

| Rule | Value |
|------|-------|
| Line length | 120 chars max |
| Indentation | 4 spaces |
| Quotes | Double quotes |
| Integer types | Long form (`uint256` not `uint`) |
| Number formatting | Underscores at thousands (`1_000_000`) |
| Bracket spacing | Enabled |
| Import sorting | Enabled |
| Wrap comments | Disabled |

### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Internal/private functions | `_` prefix | `function _validateInput()` |
| Internal/private variables | `_` prefix | `uint256 private _totalSupply;` |
| Function params (collision) | `_` prefix | `function set(uint256 _value)` |
| Interfaces | `I` prefix | `interface IDopplerHook` |
| Constants | UPPER_SNAKE_CASE | `uint256 constant MAX_FEE = 1e18;` |
| Events | Past tense | `event TokensBurned(...)` |
| Custom errors | Domain prefix | `error Doppler_InvalidInput();` |

### Import Style

Use named imports with aliases. Order: external libs, then internal.

```solidity
// External
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { FixedPointMathLib } from "@solady/utils/FixedPointMathLib.sol";

// Internal
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";
```

---

## Error Handling

- Use custom errors, not `require` strings
- Follow EIP-6093 rationale for error naming
- Prefix with component name: `Doppler_`, `Airlock_`, etc.
- Include relevant parameters in error

```solidity
error Doppler_InvalidTimeRange(uint256 start, uint256 end);
error Doppler_MaxProceedsReached(uint256 current, uint256 max);
```

---

## Documentation

- All public/external functions must have natspec
- External contracts must inherit from documented interfaces
- Use `@notice`, `@param`, `@return`, `@dev` tags

```solidity
/// @notice Initializes the pool with the given parameters
/// @param key The pool key containing currency and fee info
/// @param data Encoded initialization parameters
/// @return success True if initialization succeeded
function initialize(PoolKey calldata key, bytes calldata data) external returns (bool success);
```

---

## Testing Requirements

- Unit tests for all new functions
- Fuzz tests for math-heavy code
- Invariant tests for state machines and complex flows
- Integration tests for cross-contract interactions
- No flaky tests allowed
- Target close to 100% coverage

---

## Environment Configuration

Copy `.env.example` to `.env` and configure:

```bash
# Test behavior toggles
IS_TOKEN_0=TRUE
USING_ETH=FALSE
V4_FEE=100

# RPC endpoints (for fork tests/deployment)
MAINNET_RPC_URL=""
BASE_MAINNET_RPC_URL=""
```

---

## Key Files

| File | Purpose |
|------|---------|
| `foundry.toml` | Foundry config, formatter settings, profiles |
| `Makefile` | Build/test/deploy commands |
| `.env.example` | Environment variable template |
| `CLAUDE.md` | Project-specific AI instructions |

---

## Subrepos

The `lib/` folder contains vendored dependencies. Most follow similar Foundry conventions.

**universal-router** (`lib/universal-router/`): Uses both Hardhat and Foundry. Has its own `package.json` with `yarn test` commands.

For subrepo-specific guidelines, see their `CONTRIBUTING.md` files:
- `lib/v4-core/CONTRIBUTING.md`
- `lib/v4-periphery/CONTRIBUTING.md`

---

## Common Pitfalls

1. **Don't suppress type errors** — Never use `as any`, `@ts-ignore`, or cast away safety
2. **Don't modify vendored libs** — Make changes upstream or fork properly
3. **Run `forge fmt` before commits** — CI will fail on format violations
4. **Use `--via-ir` for accurate gas** — Default builds may differ from CI
5. **Check `.env` config** — Test behavior changes based on env vars

---

## References

- [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- [Foundry Book](https://book.getfoundry.sh/)
- [Uniswap v4 Docs](https://docs.uniswap.org/)
- [Doppler Docs](https://docs.doppler.lol)
