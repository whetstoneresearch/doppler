
# Spec: Uniswap v4 Multicurve Migration into Hooked Pools via `DopplerHookInitializer`

**Status:** Draft  
**Primary goal:** Enable the existing Airlock v4 migrator flow to migrate proceeds into a *fresh Uniswap v4 pool whose `hooks` are `DopplerHookInitializer`*, so swap-time Doppler hooks (e.g., Rehype) and “virtual migration” (`graduate()`) are supported post-migration — while keeping the code diff as small as possible.

---

## 0. Context / Existing System (as in repo)

### Relevant files
- **Airlock migration flow**
  - `src/Airlock.sol`
- **Auction initializer (flagship)**
  - `src/initializers/UniswapV4Initializer.sol`
  - `src/initializers/Doppler.sol` (auction hook)
- **Existing v4 multicurve migrator**
  - `src/migrators/UniswapV4MulticurveMigrator.sol`
- **Doppler hook framework**
  - `src/initializers/DopplerHookInitializer.sol`
  - `src/base/BaseDopplerHook.sol`
  - Example Doppler hook: `src/dopplerHooks/RehypeDopplerHook.sol`

---

## 1. Goals

### Must-have
1. Keep Airlock migration flow unchanged
2. Migrate into a Uniswap v4 pool that supports hooks
3. Support a single Doppler hook
4. Support virtual migration via `graduate()`
5. No migrate-out from destination pool
6. Fixed or dynamic fee support, with safety checks
7. Allow upgrades until graduation (current behavior)

### Non-goals
- Multiple Doppler hooks per pool
- Changes to multicurve math or locker semantics
- Changes to Airlock or Doppler auction logic

---

## 2. Design Overview

- Introduce a new migrator: `DopplerHookMigrator.sol`
- Add `initializeMigrationPool(...)` to `DopplerHookInitializer`
- Destination pool is initialized *through* the initializer to satisfy hook access control
- Airlock, Doppler, and UniswapV4Initializer remain unchanged

---

## 3. DopplerHookMigrator

### Responsibilities
- Store multicurve + hook config
- Initialize hooked destination pool via initializer
- Mint multicurve liquidity into `StreamableFeesLockerV2`

### Constructor
```solidity
constructor(
  address airlock,
  IPoolManager poolManager,
  DopplerHookInitializer dopplerHookInitializer,
  StreamableFeesLockerV2 locker
)
```

### Init ABI Encoding
```solidity
abi.encode(
  uint24 feeOrInitialDynamicFee,
  int24 tickSpacing,
  uint32 lockDuration,
  BeneficiaryData[] beneficiaries,
  Curve[] curves,
  bool useDynamicFee,
  address dopplerHook,
  bytes onInitializationCalldata,
  int24 farTick,
  bytes onGraduationCalldata
)
```

### ETH Handling
```solidity
receive() external payable {}
```

---

## 4. DopplerHookInitializer Extension

### New Function
```solidity
function initializeMigrationPool(
  address asset,
  PoolKey calldata poolKey,
  uint160 sqrtPriceX96,
  int24 farTick,
  uint24 feeOrInitialDynamicFee,
  address dopplerHook,
  bytes calldata onInitializationCalldata,
  bytes calldata onGraduationCalldata
) external;
```

### Key Properties
- Callable only by configured migrator
- Initializes pool internally
- Registers hook routing state
- Sets status = Locked
- Enables virtual migration (`graduate()`)

---

## 5. Dynamic Fee Requirement Flag

Add to `BaseDopplerHook.sol`:
```solidity
uint256 constant REQUIRES_DYNAMIC_LP_FEE_FLAG = 1 << 3;
```

Enforced in:
- `initializeMigrationPool`
- `setDopplerHook`

---

## 6. Virtual Migration

- Uses existing `graduate(asset)` logic
- No liquidity movement
- No distribution changes
- Graduation freezes future upgrades (unchanged behavior)

---

## 7. Governance / Ops

1. Deploy `DopplerHookMigrator`
2. Whitelist as liquidity migrator in Airlock
3. Approve migrator in `StreamableFeesLockerV2`
4. Enable Doppler hooks via `setDopplerHookState`

---

## 8. Test Checklist

- Migration initializes hooked pool
- Swap triggers Doppler hook
- Fixed fee + compatible hook works
- Fixed fee + requires-dynamic hook reverts
- Virtual migration triggers `onGraduation`
- Exit liquidity from migration pool is impossible

---

## 9. Summary

This design introduces a minimal, composable extension to the Uniswap v4 migration flow, allowing Doppler auctions to migrate into hooked pools with full support for Rehype and future Doppler hooks, while preserving Airlock invariants and existing migration semantics.
