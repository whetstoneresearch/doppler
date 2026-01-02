# RehypeDopplerHook Invariant Testing Specification

**Version**: 1.0  
**Created**: January 2026  
**Status**: Planning  

---

## Table of Contents

1. [Overview](#1-overview)
2. [System Under Test](#2-system-under-test)
3. [Risk Analysis](#3-risk-analysis)
4. [Test Architecture](#4-test-architecture)
5. [Invariants](#5-invariants)
6. [Handler Design](#6-handler-design)
7. [Edge Cases](#7-edge-cases)
8. [Implementation Plan](#8-implementation-plan)
9. [Success Criteria](#9-success-criteria)
10. [Appendix](#10-appendix)

---

## 1. Overview

### 1.1 Purpose

Create comprehensive invariant tests for `RehypeDopplerHook.sol` to ensure **swaps never revert unexpectedly** due to the hook's internal operations. The hook performs complex fee collection, distribution, buybacks, and LP reinvestment on every swap, creating numerous potential failure points.

### 1.2 Primary Goal

> **Swaps must not revert unexpectedly.**

Any revert during a swap that is not due to standard AMM conditions (price limits, insufficient liquidity) represents a critical bug that could brick the pool.

### 1.3 Secondary Goals

- Verify fee accounting integrity
- Ensure hook solvency (can always pay what it owes)
- Confirm LP position management correctness
- Validate fee distribution configuration consistency

### 1.4 Scope

| In Scope | Out of Scope |
|----------|--------------|
| `RehypeDopplerHook._onSwap()` | `DopplerHookInitializer` internal logic |
| `RehypeDopplerHook._onInitialization()` | Airlock creation flow |
| Fee distribution mechanics | Governance/timelock interactions |
| LP position management | Migration/graduation flows |
| Buyback execution | Other Doppler hooks |
| `collectFees()` function | |
| `setFeeDistributionByBeneficiary()` | |

---

## 2. System Under Test

### 2.1 Contract Overview

**File**: `src/dopplerHooks/RehypeDopplerHook.sol`

The RehypeDopplerHook is a Uniswap V4 hook that intercepts swaps to:
1. Collect fees from swap output
2. Execute buybacks (asset and numeraire)
3. Reinvest fees as full-range LP
4. Accumulate remaining fees for beneficiaries

### 2.2 Key State Variables

```solidity
// Position data for LP reinvestment
mapping(PoolId => Position) public getPosition;

// Fee distribution configuration (must sum to WAD)
mapping(PoolId => FeeDistributionInfo) public getFeeDistributionInfo;

// Fee tracking
mapping(PoolId => HookFees) public getHookFees;

// Pool metadata
mapping(PoolId => PoolInfo) public getPoolInfo;
```

### 2.3 Data Structures

```solidity
struct FeeDistributionInfo {
    uint256 assetBuybackPercentWad;      // % of fees for buying asset
    uint256 numeraireBuybackPercentWad;  // % of fees for buying numeraire
    uint256 beneficiaryPercentWad;       // % of fees for beneficiary
    uint256 lpPercentWad;                // % of fees for LP reinvestment
}

struct HookFees {
    uint128 fees0;              // Temporary: current swap's fees (token0)
    uint128 fees1;              // Temporary: current swap's fees (token1)
    uint128 beneficiaryFees0;   // Accumulated: claimable by beneficiary
    uint128 beneficiaryFees1;   // Accumulated: claimable by beneficiary
    uint24 customFee;           // Fee rate (in parts per million)
}

struct PoolInfo {
    address asset;
    address numeraire;
    address buybackDst;  // Receives buyback tokens and beneficiary fees
}

struct Position {
    int24 tickLower;     // Always min usable tick (full range)
    int24 tickUpper;     // Always max usable tick (full range)
    uint128 liquidity;   // Accumulated LP liquidity
    bytes32 salt;        // Position identifier
}
```

### 2.4 Constants

```solidity
uint256 constant MAX_SWAP_FEE = 1e6;           // 100% in ppm
uint128 constant EPSILON = 1e6;                // Minimum fee threshold
uint256 constant MAX_REBALANCE_ITERATIONS = 15; // Binary search limit
uint256 constant WAD = 1e18;                   // 100% in wad
```

### 2.5 Core Flow: `_onSwap()`

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           _onSwap() Flow                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. EARLY EXIT CHECK                                                    │
│     └─ If sender == address(this), return (skip internal swaps)         │
│                                                                         │
│  2. COLLECT SWAP FEES                                                   │
│     └─ _collectSwapFees()                                               │
│        ├─ Calculate fee from output amount                              │
│        ├─ Check poolManager has sufficient balance                      │
│        ├─ poolManager.take() fee to hook                                │
│        └─ Update fees0/fees1                                            │
│                                                                         │
│  3. EARLY EXIT CHECK                                                    │
│     └─ If fees0 <= EPSILON && fees1 <= EPSILON, return                  │
│                                                                         │
│  4. CALCULATE DISTRIBUTION AMOUNTS                                      │
│     ├─ assetBuybackAmountIn = fees * assetBuybackPercentWad / WAD       │
│     ├─ numeraireBuybackAmountIn = fees * numeraireBuybackPercentWad     │
│     └─ lpAmount0/1 = fees * lpPercentWad / WAD                          │
│                                                                         │
│  5. EXECUTE ASSET BUYBACK (if amount > 0)                               │
│     ├─ _executeSwap() - swap numeraire for asset                        │
│     ├─ Transfer asset to buybackDst                                     │
│     └─ Update balance tracking                                          │
│                                                                         │
│  6. EXECUTE NUMERAIRE BUYBACK (if amount > 0)                           │
│     ├─ _simulateSwap() - check if swap is viable                        │
│     ├─ Verify poolManager has output balance                            │
│     ├─ _executeSwap() - swap asset for numeraire                        │
│     ├─ Transfer numeraire to buybackDst                                 │
│     └─ Update balance tracking                                          │
│                                                                         │
│  7. LP REINVESTMENT (if shouldSwap && swapAmountIn > 0)                 │
│     ├─ _rebalanceFees() - binary search for optimal swap                │
│     │   ├─ Calculate excess amounts                                     │
│     │   ├─ Binary search (up to 15 iterations)                          │
│     │   └─ Return optimal swap parameters                               │
│     ├─ Verify poolManager has output balance                            │
│     ├─ _executeSwap() - rebalance swap                                  │
│     ├─ _addFullRangeLiquidity()                                         │
│     │   ├─ Calculate liquidity from amounts                             │
│     │   ├─ poolManager.modifyLiquidity()                                │
│     │   ├─ _settleDelta() / _collectDelta()                             │
│     │   └─ Update position.liquidity                                    │
│     └─ Update balance tracking                                          │
│                                                                         │
│  8. ACCUMULATE BENEFICIARY FEES                                         │
│     ├─ beneficiaryFees0 += remaining balance0                           │
│     ├─ beneficiaryFees1 += remaining balance1                           │
│     └─ Reset fees0 = fees1 = 0                                          │
│                                                                         │
│  9. RETURN                                                              │
│     └─ Return (feeCurrency, hookDelta)                                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.6 Internal Helper Functions

| Function | Purpose | Potential Failure Modes |
|----------|---------|------------------------|
| `_collectSwapFees()` | Take fee from swap output | Insufficient poolManager balance |
| `_executeSwap()` | Execute internal swap | Price limits, no liquidity |
| `_simulateSwap()` | Quoter simulation | Quoter reverts (caught by try/catch) |
| `_rebalanceFees()` | Binary search for LP rebalance | Edge cases in search logic |
| `_addFullRangeLiquidity()` | Add LP position | Zero liquidity, settlement failure |
| `_calculateExcess()` | Compute imbalanced amounts | Arithmetic edge cases |
| `_settleDelta()` | Pay poolManager | Insufficient hook balance |
| `_collectDelta()` | Receive from poolManager | None expected |
| `_pay()` | Transfer to poolManager | ERC20 transfer failure |

---

## 3. Risk Analysis

### 3.1 Critical Risk Areas

#### 3.1.1 Insufficient Balance for Internal Swaps

**Location**: `_executeSwap()` lines 301-329

**Risk**: Hook attempts to swap more tokens than it holds.

**Trigger Conditions**:
- Accumulated fees are miscalculated
- Balance tracking variables drift from actual balances
- Arithmetic overflow/underflow in balance calculations

**Mitigation in Code**: None explicit - relies on correct accounting.

**Test Strategy**: Track ghost balances and compare to actual after each operation.

#### 3.1.2 Settlement Failures

**Location**: `_settleDelta()` lines 388-395, `_pay()` lines 412-425

**Risk**: Hook cannot settle its debt to poolManager after internal operations.

**Trigger Conditions**:
- Hook balance < required settlement amount
- ERC20 transfer fails
- ETH transfer fails (for native ETH pools)

**Mitigation in Code**: None explicit.

**Test Strategy**: Invariant checking hook solvency after every swap.

#### 3.1.3 LP Addition Failures

**Location**: `_addFullRangeLiquidity()` lines 337-385

**Risk**: `poolManager.modifyLiquidity()` reverts or calculates zero liquidity.

**Trigger Conditions**:
- Amounts too small for meaningful liquidity
- Price at tick boundary
- Tick calculation errors

**Mitigation in Code**: Returns (0,0) if `liquidityDelta == 0`.

**Test Strategy**: Fuzz small amounts near EPSILON.

#### 3.1.4 Rebalance Binary Search Failures

**Location**: `_rebalanceFees()` lines 214-290

**Risk**: Binary search fails to find valid swap parameters or enters infinite loop.

**Trigger Conditions**:
- Extreme price ratios
- Very small or very large amounts
- Edge cases where `low == high`

**Mitigation in Code**: 
- `MAX_REBALANCE_ITERATIONS = 15` limit
- Multiple break conditions
- Returns `(false, ...)` on failure

**Test Strategy**: Fuzz with extreme fee distributions (100% LP) and varying amounts.

#### 3.1.5 Arithmetic Overflow/Underflow

**Location**: Multiple, especially balance tracking in `_onSwap()`

**Risk**: Solidity 0.8+ reverts on overflow, but underflow in balance subtraction could occur.

**Specific Concerns**:
```solidity
// Line 158-159: Could underflow if assetBuybackAmountInUsed > balance
balance0 = isToken0 ? balance0 : balance0 - assetBuybackAmountInUsed;
balance1 = isToken0 ? balance1 - assetBuybackAmountInUsed : balance1;

// Line 192-193: Complex calculation with multiple subtractions
balance0 = zeroForOne ? balance0 - swapAmountIn - amount0Added : balance0 + swapAmountOut - amount0Added;
```

**Test Strategy**: Fuzz edge case amounts that could trigger underflow.

### 3.2 Medium Risk Areas

#### 3.2.1 Quoter Failures

**Location**: `_simulateSwap()` lines 432-485

**Risk**: Quoter reverts unexpectedly, causing simulation to fail.

**Mitigation in Code**: Wrapped in try/catch, returns empty simulation on failure.

**Test Strategy**: Ensure swaps still succeed when simulation fails (graceful degradation).

#### 3.2.2 Fee Distribution Configuration

**Location**: `setFeeDistributionByBeneficiary()` lines 601-632

**Risk**: Invalid fee distributions could be set.

**Mitigation in Code**: Requires sum == WAD.

**Test Strategy**: Invariant to verify sum always equals WAD.

### 3.3 Low Risk Areas

- Pool info consistency (set once at initialization)
- Custom fee bounds (set at initialization, not mutable)
- Position tick bounds (always full range)

---

## 4. Test Architecture

### 4.1 File Structure

```
doppler/test/invariant/rehype/
├── SPECIFICATION.md        # This document
├── RehypeSetup.sol         # Base test setup (Airlock, tokens, etc.)
├── RehypeHandler.sol       # Handler with fuzzed actions
├── RehypeInvariants.t.sol  # Invariant test definitions
└── RehypeHelpers.sol       # Optional: shared utilities
```

### 4.2 Dependency Graph

```
┌─────────────────────────────────────────────────────────────────┐
│                     RehypeInvariants.t.sol                      │
│                   (Invariant definitions)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       RehypeHandler.sol                         │
│              (Fuzzed actions, ghost variables)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       RehypeSetup.sol                           │
│            (Airlock, Initializer, Hook deployment)              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Deployers                               │
│               (Uniswap V4 test utilities)                       │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 Actor Model

**Number of Actors**: 3-5 (configurable)

**Rationale**: 
- RehypeDopplerHook has **no per-user state**
- All fees go to a single `buybackDst`
- Multiple actors test that swaps from different addresses don't interfere
- More actors provide diminishing returns

**Actor Management**:
```solidity
AddressSet internal actors;

modifier createActor() {
    currentActor = msg.sender;
    actors.add(msg.sender);
    // ...
}

modifier useActor(uint256 seed) {
    currentActor = actors.rand(seed);
    // ...
}
```

### 4.4 Test Variants

| Variant | Numeraire | Purpose |
|---------|-----------|---------|
| `RehypeInvariantsTest` | ERC20 | Primary test suite |
| `RehypeInvariantsETHTest` | Native ETH | ETH handling paths |

### 4.5 Foundry Configuration

```toml
[invariant]
runs = 256              # Number of fuzzing runs
depth = 100             # Calls per run
fail_on_revert = false  # Capture reverts in handler
dictionary_weight = 80  # Use discovered values
include_storage = true  # Include storage in dictionary
include_push_bytes = true
```

**Extended Configuration** (for thorough testing):
```toml
[invariant.thorough]
runs = 1024
depth = 200
```

---

## 5. Invariants

### 5.1 Primary Invariants (Must Pass)

#### INV-001: Swaps Never Revert Unexpectedly

**Priority**: CRITICAL

**Description**: Any swap that reverts due to hook internal errors (not standard AMM conditions) is a critical bug.

**Implementation**:
```solidity
function invariant_SwapsNeverRevertUnexpectedly() public view {
    assertEq(
        handler.ghost_unexpectedReverts(),
        0,
        "CRITICAL: Unexpected swap revert occurred"
    );
}
```

**Expected Reverts** (acceptable):
- `PriceLimitAlreadyExceeded`
- `InvalidSqrtPrice`
- `NotEnoughLiquidity`
- `SwapAmountCannotBeZero`

**Unexpected Reverts** (bugs):
- Arithmetic overflow/underflow
- Transfer failures
- Settlement failures
- Any other revert

#### INV-002: Fee Distribution Sums to WAD

**Priority**: HIGH

**Description**: Fee distribution percentages must always total 100% (1e18).

**Implementation**:
```solidity
function invariant_FeeDistributionSumsToWAD() public view {
    (uint256 a, uint256 b, uint256 c, uint256 d) = 
        hook.getFeeDistributionInfo(poolId);
    assertEq(a + b + c + d, WAD);
}
```

#### INV-003: Hook Solvency for Beneficiary Fees

**Priority**: HIGH

**Description**: Hook must always hold enough tokens to cover accumulated beneficiary fees.

**Implementation**:
```solidity
function invariant_HookSolventForBeneficiaryFees() public view {
    (,,, uint128 beneficiaryFees0, uint128 beneficiaryFees1) = 
        hook.getHookFees(poolId);
    
    assertGe(currency0.balanceOf(address(hook)), beneficiaryFees0);
    assertGe(currency1.balanceOf(address(hook)), beneficiaryFees1);
}
```

#### INV-004: No Stuck Temporary Fees

**Priority**: HIGH

**Description**: After swap processing, temporary fee variables (fees0, fees1) must be zero.

**Implementation**:
```solidity
function invariant_NoStuckTemporaryFees() public view {
    (uint128 fees0, uint128 fees1,,,) = hook.getHookFees(poolId);
    assertEq(fees0, 0);
    assertEq(fees1, 0);
}
```

### 5.2 Secondary Invariants (Should Pass)

#### INV-005: LP Liquidity Monotonically Increases

**Priority**: MEDIUM

**Description**: LP position liquidity should never decrease (only additions, no removals).

**Implementation**:
```solidity
function invariant_LPLiquidityMonotonicallyIncreases() public view {
    (,, uint128 liquidity,) = hook.getPosition(poolId);
    assertGe(liquidity, handler.ghost_lastLiquidity());
}
```

#### INV-006: Position Remains Full Range

**Priority**: MEDIUM

**Description**: LP position ticks should always be min/max usable ticks.

**Implementation**:
```solidity
function invariant_PositionRemainsFullRange() public view {
    (int24 tickLower, int24 tickUpper,,) = hook.getPosition(poolId);
    assertEq(tickLower, TickMath.minUsableTick(tickSpacing));
    assertEq(tickUpper, TickMath.maxUsableTick(tickSpacing));
}
```

#### INV-007: Pool Info Immutability

**Priority**: LOW

**Description**: Pool info (asset, numeraire, buybackDst) should not change after initialization.

**Implementation**:
```solidity
function invariant_PoolInfoConsistent() public view {
    (address a, address n, address b) = hook.getPoolInfo(poolId);
    assertEq(a, expectedAsset);
    assertEq(n, expectedNumeraire);
    assertEq(b, expectedBuybackDst);
}
```

#### INV-008: Custom Fee Within Bounds

**Priority**: LOW

**Description**: Custom fee should never exceed MAX_SWAP_FEE (1e6).

**Implementation**:
```solidity
function invariant_CustomFeeWithinBounds() public view {
    (,,,, uint24 customFee) = hook.getHookFees(poolId);
    assertLe(customFee, 1e6);
}
```

### 5.3 Invariant Summary Table

| ID | Name | Priority | Category |
|----|------|----------|----------|
| INV-001 | Swaps Never Revert Unexpectedly | CRITICAL | Liveness |
| INV-002 | Fee Distribution Sums to WAD | HIGH | Configuration |
| INV-003 | Hook Solvency | HIGH | Accounting |
| INV-004 | No Stuck Temporary Fees | HIGH | Accounting |
| INV-005 | LP Liquidity Monotonic | MEDIUM | LP Management |
| INV-006 | Position Full Range | MEDIUM | LP Management |
| INV-007 | Pool Info Immutable | LOW | Configuration |
| INV-008 | Custom Fee Bounds | LOW | Configuration |

---

## 6. Handler Design

### 6.1 Ghost Variables

#### 6.1.1 Swap Tracking

```solidity
uint256 public ghost_totalSwapAttempts;    // All swap calls
uint256 public ghost_successfulSwaps;      // Completed without revert
uint256 public ghost_expectedReverts;      // Known acceptable reverts
uint256 public ghost_unexpectedReverts;    // Bug indicators (should be 0)

uint256 public ghost_buySwaps;             // Numeraire -> Asset
uint256 public ghost_sellSwaps;            // Asset -> Numeraire
```

#### 6.1.2 Fee Tracking

```solidity
uint256 public ghost_totalFeesCollected0;
uint256 public ghost_totalFeesCollected1;

uint128 public ghost_lastBeneficiaryFees0; // For monotonic check
uint128 public ghost_lastBeneficiaryFees1;
```

#### 6.1.3 LP Tracking

```solidity
uint128 public ghost_lastLiquidity;        // For monotonic check
uint256 public ghost_liquidityAdditions;   // Count of LP additions
```

#### 6.1.4 Buyback Tracking

```solidity
uint256 public ghost_buybackDstAssetBalance;
uint256 public ghost_buybackDstNumeraireBalance;
```

#### 6.1.5 Configuration Tracking

```solidity
uint256 public ghost_feeDistributionChanges;
```

#### 6.1.6 Actor Tracking

```solidity
mapping(address => uint256) public actorAssetBalance;
mapping(address => uint256) public actorNumeraireBalance;
```

#### 6.1.7 Debug Tracking

```solidity
bytes4[] public revertSelectors;  // Collect all revert selectors
```

### 6.2 Handler Functions

#### 6.2.1 Core Swap Functions

| Function | Description | Weighting |
|----------|-------------|-----------|
| `buyExactIn(uint256)` | Buy asset with exact numeraire input | 30% |
| `sellExactIn(uint256)` | Sell asset for numeraire | 25% |

#### 6.2.2 Configuration Functions

| Function | Description | Weighting |
|----------|-------------|-----------|
| `changeFeeDistribution(uint256,uint256,uint256)` | Fuzz fee percentages | 10% |
| `setExtremeFeeDistribution(uint8)` | 100% to single category | 5% |

#### 6.2.3 Fee Collection

| Function | Description | Weighting |
|----------|-------------|-----------|
| `collectBeneficiaryFees()` | Call collectFees() | 5% |

#### 6.2.4 Edge Case Functions

| Function | Description | Weighting |
|----------|-------------|-----------|
| `buyTinyAmount()` | Amounts near EPSILON | 5% |
| `buyLargeAmount()` | Stress test large amounts | 5% |
| `rapidBuys(uint8)` | Sequential same-direction swaps | 5% |
| `alternateBuySell(uint8)` | Buy-sell-buy-sell pattern | 10% |

### 6.3 Error Handling

```solidity
function _handleSwapError(bytes memory err) internal {
    bytes4 selector;
    assembly {
        selector := mload(add(err, 0x20))
    }
    
    revertSelectors.push(selector);

    // Known acceptable reverts
    if (
        selector == bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)")) ||
        selector == bytes4(keccak256("InvalidSqrtPrice()")) ||
        selector == bytes4(keccak256("NotEnoughLiquidity()")) ||
        selector == bytes4(keccak256("SwapAmountCannotBeZero()"))
    ) {
        ghost_expectedReverts++;
    } else {
        // UNEXPECTED - This is a bug!
        ghost_unexpectedReverts++;
    }
}
```

### 6.4 Selector Targets

```solidity
bytes4[] memory selectors = new bytes4[](9);
selectors[0] = handler.buyExactIn.selector;
selectors[1] = handler.sellExactIn.selector;
selectors[2] = handler.changeFeeDistribution.selector;
selectors[3] = handler.setExtremeFeeDistribution.selector;
selectors[4] = handler.collectBeneficiaryFees.selector;
selectors[5] = handler.buyTinyAmount.selector;
selectors[6] = handler.buyLargeAmount.selector;
selectors[7] = handler.rapidBuys.selector;
selectors[8] = handler.alternateBuySell.selector;

targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
```

---

## 7. Edge Cases

### 7.1 Amount Edge Cases

| Case | Description | Handler Function |
|------|-------------|------------------|
| Tiny amounts | < EPSILON (1e6) | `buyTinyAmount()` |
| Zero amounts | Exactly 0 | Bounded to prevent |
| Large amounts | 100-1000 ETH | `buyLargeAmount()` |
| Max amounts | Near uint128.max | Optional fuzz |

### 7.2 Fee Distribution Edge Cases

| Case | Distribution | Handler Function |
|------|--------------|------------------|
| 100% Asset Buyback | `(WAD, 0, 0, 0)` | `setExtremeFeeDistribution(0)` |
| 100% Numeraire Buyback | `(0, WAD, 0, 0)` | `setExtremeFeeDistribution(1)` |
| 100% Beneficiary | `(0, 0, WAD, 0)` | `setExtremeFeeDistribution(2)` |
| 100% LP | `(0, 0, 0, WAD)` | `setExtremeFeeDistribution(3)` |
| Even split | `(0.25, 0.25, 0.25, 0.25)` | Random fuzz |
| Zero fee | customFee = 0 | Separate setup |

### 7.3 Swap Pattern Edge Cases

| Case | Description | Handler Function |
|------|-------------|------------------|
| Rapid sequential | Multiple same-direction swaps | `rapidBuys()` |
| Alternating | Buy-sell-buy-sell | `alternateBuySell()` |
| All buys | Only buying, no selling | Fuzz weighting |
| All sells | Only selling (after buys) | Fuzz weighting |

### 7.4 Price Edge Cases

| Case | Description | How Triggered |
|------|-------------|---------------|
| Near min price | Price at MIN_SQRT_PRICE | Large buys of asset |
| Near max price | Price at MAX_SQRT_PRICE | Large sells of asset |
| Price limit hit | Swap limited by sqrtPriceLimitX96 | Large swaps |

### 7.5 Token Configuration Edge Cases

| Case | Description | Test Variant |
|------|-------------|--------------|
| Asset is token0 | asset < numeraire | Random per setup |
| Asset is token1 | asset > numeraire | Random per setup |
| ETH numeraire | Native ETH as numeraire | `RehypeInvariantsETHTest` |
| ERC20 numeraire | Standard ERC20 | `RehypeInvariantsTest` |

---

## 8. Implementation Plan

### 8.1 Phase 1: Setup Infrastructure

**Goal**: Create base setup that deploys full Airlock stack with RehypeDopplerHook.

**Files**:
- `RehypeSetup.sol`

**Tasks**:
- [ ] Port setup from `RehypeDopplerHook.t.sol` integration tests
- [ ] Add configurable fee distribution parameters
- [ ] Add ETH/ERC20 numeraire toggle
- [ ] Verify pool creation works

**Acceptance Criteria**:
- Can deploy hook and create pool with any fee distribution
- Can perform basic swap through setup

### 8.2 Phase 2: Basic Handler

**Goal**: Implement core swap functions with error handling.

**Files**:
- `RehypeHandler.sol`

**Tasks**:
- [ ] Implement `buyExactIn()`
- [ ] Implement `sellExactIn()`
- [ ] Implement error categorization
- [ ] Add ghost variable tracking
- [ ] Add actor management

**Acceptance Criteria**:
- Handler can execute buys and sells
- Errors are properly categorized
- Ghost variables track state correctly

### 8.3 Phase 3: Primary Invariants

**Goal**: Implement and verify critical invariants.

**Files**:
- `RehypeInvariants.t.sol`

**Tasks**:
- [ ] Implement INV-001 (Swaps Never Revert Unexpectedly)
- [ ] Implement INV-002 (Fee Distribution Sums to WAD)
- [ ] Implement INV-003 (Hook Solvency)
- [ ] Implement INV-004 (No Stuck Fees)
- [ ] Run initial fuzzing campaign
- [ ] Debug any failures

**Acceptance Criteria**:
- All primary invariants pass with 256 runs, depth 100
- No unexpected reverts

### 8.4 Phase 4: Edge Case Functions

**Goal**: Add handler functions for edge cases.

**Tasks**:
- [ ] Implement `changeFeeDistribution()`
- [ ] Implement `setExtremeFeeDistribution()`
- [ ] Implement `collectBeneficiaryFees()`
- [ ] Implement `buyTinyAmount()`
- [ ] Implement `buyLargeAmount()`
- [ ] Implement `rapidBuys()`
- [ ] Implement `alternateBuySell()`

**Acceptance Criteria**:
- All edge case functions work without errors
- Invariants still pass with new functions

### 8.5 Phase 5: Secondary Invariants

**Goal**: Add remaining invariants.

**Tasks**:
- [ ] Implement INV-005 (LP Liquidity Monotonic)
- [ ] Implement INV-006 (Position Full Range)
- [ ] Implement INV-007 (Pool Info Immutable)
- [ ] Implement INV-008 (Custom Fee Bounds)

**Acceptance Criteria**:
- All invariants pass

### 8.6 Phase 6: ETH Variant

**Goal**: Test with native ETH as numeraire.

**Files**:
- Update `RehypeSetup.sol`
- Add `RehypeInvariantsETHTest` in `RehypeInvariants.t.sol`

**Tasks**:
- [ ] Update setup for ETH handling
- [ ] Update handler for ETH transfers
- [ ] Create ETH test variant
- [ ] Run fuzzing campaign

**Acceptance Criteria**:
- ETH variant passes all invariants

### 8.7 Phase 7: Extended Fuzzing

**Goal**: Run thorough fuzzing campaign.

**Tasks**:
- [ ] Run with extended config (1024 runs, depth 200)
- [ ] Analyze any failures
- [ ] Fix bugs or update expected reverts
- [ ] Document findings

**Acceptance Criteria**:
- All invariants pass with extended configuration
- No unexpected reverts discovered

---

## 9. Success Criteria

### 9.1 Minimum Success (Must Achieve)

- [ ] INV-001 passes: Zero unexpected reverts in 256 runs
- [ ] INV-002 passes: Fee distribution always sums to WAD
- [ ] INV-003 passes: Hook always solvent
- [ ] INV-004 passes: No stuck temporary fees
- [ ] Tests run in < 5 minutes

### 9.2 Target Success (Should Achieve)

- [ ] All 8 invariants pass
- [ ] Both ERC20 and ETH variants pass
- [ ] Extended fuzzing (1024 runs) passes
- [ ] All edge case functions implemented
- [ ] < 0.1% expected revert rate

### 9.3 Stretch Goals (Nice to Have)

- [ ] Multi-pool variant (if deemed useful)
- [ ] Gas usage tracking
- [ ] Coverage report showing >90% of hook code exercised
- [ ] Mutation testing to verify invariant strength

---

## 10. Appendix

### 10.1 Related Files

| File | Purpose |
|------|---------|
| `src/dopplerHooks/RehypeDopplerHook.sol` | System under test |
| `src/types/RehypeTypes.sol` | Type definitions |
| `src/initializers/DopplerHookInitializer.sol` | Pool initialization |
| `test/integration/RehypeDopplerHook.t.sol` | Integration tests (reference) |
| `test/invariant/DopplerHandler.sol` | Existing handler (reference) |
| `test/invariant/AddressSet.sol` | Actor management utility |

### 10.2 Execution Commands

```bash
# Basic run
forge test --match-contract RehypeInvariants -vvv

# Extended run
forge test --match-contract RehypeInvariants \
    --invariant-runs 1024 \
    --invariant-depth 200 \
    -vvv

# Single invariant
forge test --match-test invariant_SwapsNeverRevertUnexpectedly -vvv

# With gas report
forge test --match-contract RehypeInvariants --gas-report

# Debug failing invariant
forge test --match-contract RehypeInvariants -vvvv --debug
```

### 10.3 Glossary

| Term | Definition |
|------|------------|
| WAD | 1e18, represents 100% in fixed-point math |
| EPSILON | 1e6, minimum fee threshold for processing |
| Ghost Variable | Test-side variable tracking expected state |
| Invariant | Property that must always hold true |
| Handler | Contract that fuzzer calls to interact with SUT |
| SUT | System Under Test (RehypeDopplerHook) |
| Buyback | Swapping fees to purchase asset/numeraire |
| LP Reinvestment | Adding collected fees as liquidity |

### 10.4 Change Log

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Jan 2026 | Initial specification |

---

## Approval

- [ ] Engineering Review
- [ ] Security Review
- [ ] Ready for Implementation
