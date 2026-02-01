# DERC20 v2 — Multi‑Schedule Vesting Specification (Draft v0.2)

This document specifies a new version of `DERC20` that supports **multiple vesting schedules** and **multiple tranches per beneficiary**, while preserving existing:

- pool-lock semantics (`lockPool`, `unlockPool`, `_update` restriction)
- inflation minting mechanism
- Permit2 infinite allowance override
- premint cap constraints (per-address and total)

This v0.2 incorporates the design decisions:

1) **Schedule start is always `block.timestamp` at deployment** (no per-schedule `start`).
2) **Multiple tranches per beneficiary are supported.**
3) **Cliff is “claim-gating”** (vesting accrues from start but can’t be claimed until `start + cliffDelta`).
4) `release` **reverts** if nothing is releasable.
5) Scope is **DERC20-focused**; consolidation with `DERC2080` and factory unification is noted as forward-compatible work.

---

## 1. Current behavior (DERC20 v1)

- Vesting is configured at deploy time via `recipients[]` + `amounts[]`.
- The contract sets one global `vestingStart = block.timestamp` and one global `vestingDuration`.
- Every recipient shares the same timing.
- Vested tokens are pre-minted to `address(this)` and claimed via `release()`.

Problem: shared timing is awkward for real distributions.

---

## 2. Goals

1. Support **many distinct vesting timelines** (different durations/cliffs).
2. Support **multiple tranches** (multiple schedules) per beneficiary.
3. Add a **traditional cliff** capability (claim-gating).
4. Maintain existing behavior for pool lock, inflation, Permit2.
5. Keep the deployment model “single-shot” (allocations fixed at deploy).

---

## 3. Non-goals

- Revocation / clawback.
- Non-linear vesting curves.
- Post-deployment additions/edits of schedules or allocations (could be a v2.1 extension).

---

## 4. High-level design

### 4.1 Global start, schedule deltas

- `vestingStart` is **always** set to `block.timestamp` in the constructor.
- Each schedule is defined by:
  - `duration` (seconds from `vestingStart` until fully vested)
  - `cliff` (seconds from `vestingStart` until tokens become claimable)

Cliffs are always **deltas**.

### 4.2 Registry + allocations

- Create a registry `vestingSchedules[scheduleId]`.
- Allocate `(beneficiary, scheduleId, amount)` entries.

Multiple tranches for the same beneficiary are achieved by allocating them to multiple `scheduleId`s.

**Important simplification:** if the constructor receives multiple allocations for the same `(beneficiary, scheduleId)`, the implementation MAY aggregate them into one allocation (same payout curve either way).

---

## 5. Data model

### 5.1 Structs

```solidity
struct VestingSchedule {
    uint64 cliff;    // seconds after vestingStart until claimable
    uint64 duration; // seconds after vestingStart until fully vested
}

struct VestingData {
    uint256 totalAmount;
    uint256 releasedAmount;
}
```

### 5.2 Storage

```solidity
uint256 public immutable vestingStart;       // block.timestamp at deployment
uint256 public immutable vestedTotalAmount;  // sum(all allocations)

VestingSchedule[] public vestingSchedules;   // scheduleId = index

// beneficiary => scheduleId => vesting totals
mapping(address => mapping(uint256 => VestingData)) public vestingOf;

// beneficiary => list of scheduleIds they have allocations in
mapping(address => uint256[]) internal _scheduleIdsOf;
// beneficiary => scheduleId => whether scheduleId already present in _scheduleIdsOf
mapping(address => mapping(uint256 => bool)) internal _hasSchedule;
```

Notes:
- `_scheduleIdsOf` enables a `release()` that “just works” like v1, without forcing the user to know schedule IDs.
- If minimizing storage is a priority, an alternative is to remove `_scheduleIdsOf` and require `releaseMany(uint256[] scheduleIds)` instead.

---

## 6. Constructor and initialization

### 6.1 Conceptual constructor signature

(Exact signature is up to the coder; this is the intended parameter set.)

- `name_`, `symbol_`
- `initialSupply`
- `recipient` — receives `initialSupply - vestedTotalAmount`
- `owner_` — token owner
- `yearlyMintRate_`
- `VestingSchedule[] schedules_`
- `address[] beneficiaries_`
- `uint256[] scheduleIds_`
- `uint256[] amounts_`
- `tokenURI_`

### 6.2 Validation rules

1. **Inflation cap** (unchanged):
   - `yearlyMintRate_ <= MAX_YEARLY_MINT_RATE_WAD`.

2. **Array lengths:**
   - `beneficiaries_.length == scheduleIds_.length == amounts_.length`.

3. **Schedule validity** (for each schedule `s`):
   - `s.duration > 0`.
   - `s.cliff <= s.duration`.

4. **Allocation validity:**
   - `scheduleIds_[i] < schedules_.length`.
   - `beneficiaries_[i] != address(0)`.
   - `amounts_[i] > 0`.

5. **Premint caps (same semantics as DERC20 v1):**

   Define:

   - `maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1e18` (20% in current DERC20)
   - `maxTotalPreMint      = initialSupply * MAX_TOTAL_PRE_MINT_WAD / 1e18` (20% in current DERC20)

   Requirements:

   - For each beneficiary, `sum(amounts allocated to beneficiary across all schedules) <= maxPreMintPerAddress`.
   - `vestedTotalAmount <= maxTotalPreMint`.
   - `vestedTotalAmount < initialSupply`.

### 6.3 Allocation bookkeeping rules

For each allocation `(beneficiary, scheduleId, amount)`:

- `vestingOf[beneficiary][scheduleId].totalAmount += amount`.
- If this is the first allocation for this `(beneficiary, scheduleId)`, then:
  - append `scheduleId` into `_scheduleIdsOf[beneficiary]`
  - set `_hasSchedule[beneficiary][scheduleId] = true`

### 6.4 Minting

- If `vestedTotalAmount > 0`, mint `vestedTotalAmount` to `address(this)`.
- Mint `initialSupply - vestedTotalAmount` to `recipient`.

---

## 7. Vesting math

Let:

- `t = block.timestamp`
- global `start = vestingStart`
- schedule `s = vestingSchedules[scheduleId]` with `{cliff, duration}`
- allocation total `A = vestingOf[beneficiary][scheduleId].totalAmount`
- already released `R = vestingOf[beneficiary][scheduleId].releasedAmount`

### 7.1 Linear vested amount

Because `start` is always deployment time, `t >= start` for all calls after deployment.

Compute vested amount:

- If `t >= start + s.duration`: `vested = A`
- Else: `vested = A * (t - start) / s.duration`

### 7.2 Claim-gating cliff

Claimable amount:

- If `t < start + s.cliff`: `claimable = 0`
- Else: `claimable = vested`

### 7.3 Available (releasable) amount

- `available = claimable - R`

### 7.4 Edge cases

- `duration` MUST be non-zero.
- `cliff` MAY be zero.

---

## 8. External interface

### 8.1 Views

Required views:

- `function vestingScheduleCount() external view returns (uint256)`
- `function getVestingSchedule(uint256 scheduleId) external view returns (uint64 cliff, uint64 duration)`
- `function getScheduleIdsOf(address beneficiary) external view returns (uint256[] memory)`

- `function computeAvailableVestedAmount(address beneficiary, uint256 scheduleId) external view returns (uint256)`
- `function computeAvailableVestedAmount(address beneficiary) external view returns (uint256)`
  - sums available amounts across `_scheduleIdsOf[beneficiary]`

Notes:
- The nested mapping may also be declared `public` (as shown) so Solidity auto-generates:
  - `vestingOf(beneficiary, scheduleId) -> (totalAmount, releasedAmount)`

### 8.2 Release functions

Required:

- `function release() external`
  - Releases all releasable tokens across all schedules in `_scheduleIdsOf[msg.sender]`.
  - MUST revert if total releasable across all schedules is 0.

Recommended:

- `function release(uint256 scheduleId) external`
  - Releases only from the given schedule for `msg.sender`.
  - MUST revert if releasable is 0.

Optional (UX helpers):

- `function releaseFor(address beneficiary) external`
- `function releaseFor(address beneficiary, uint256 scheduleId) external`
  - Anyone may call; tokens always transfer to `beneficiary`.
  - Same revert rule (revert if nothing releasable).

### 8.3 Revert behavior

- `release()` and `release(scheduleId)` MUST revert when the transfer amount is 0.
- Recommended error: `error NoReleasableAmount();`

---

## 9. Events

Recommended events:

```solidity
event VestingScheduleCreated(uint256 indexed scheduleId, uint64 cliff, uint64 duration);
event VestingAllocated(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);
event TokensReleased(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);
```

Notes:
- `TokensReleased` SHOULD be emitted per-schedule tranche actually released (amount > 0).
- If `release()` aggregates transfers into one `_transfer`, events are still emitted per schedule to preserve transparency.

---

## 10. Errors

Keep existing errors from v1 where useful:

- `ArrayLengthsMismatch()`
- `MaxPreMintPerAddressExceeded(amount, limit)`
- `MaxTotalPreMintExceeded(amount, limit)`
- `MaxTotalVestedExceeded(amount, limit)`
- `MaxYearlyMintRateExceeded(amount, limit)`

Add v2-specific errors (names are suggestions):

- `error UnknownScheduleId(uint256 scheduleId);`
- `error InvalidSchedule(uint256 scheduleId);` (e.g., duration==0 or cliff>duration)
- `error InvalidAllocation(uint256 index);` (optional)
- `error NoReleasableAmount();`

---

## 11. Interaction with existing DERC20 features (unchanged)

### 11.1 Pool lock

- Keep `pool`, `isPoolUnlocked`, `lockPool`, `unlockPool` unchanged.
- Keep `_update(from, to, value)` restriction:
  - if `to == pool && !isPoolUnlocked` revert `PoolLocked()`.

### 11.2 Inflation

- Keep inflation logic unchanged.
- `unlockPool()` continues to set `currentYearStart = lastMintTimestamp = block.timestamp`.

### 11.3 Permit2 infinite allowance

- Keep `allowance(owner, PERMIT_2) == type(uint256).max`.

---

## 12. TokenFactory encoding changes

`DERC20` is deployed via `TokenFactory.create(...)`. This encoding must change to include schedules + scheduleIds.

### 12.1 Suggested new encoding

Deploy a new factory (e.g., `TokenFactoryV2`) that decodes:

```solidity
(
  string name,
  string symbol,
  uint256 yearlyMintRate,
  VestingSchedule[] schedules,
  address[] beneficiaries,
  uint256[] scheduleIds,
  uint256[] amounts,
  string tokenURI
) = abi.decode(data, (...));
```

### 12.2 Backwards compatibility

- Do **not** modify the existing `TokenFactory` in-place.
- Deploy a new factory version and register/whitelist it in `Airlock`.

---

## 13. Testing requirements

Minimum unit tests:

1. **Multi-schedule**: two schedules (different durations/cliffs), same beneficiary with two tranches.
2. **Cliff gating**:
   - before cliff: `computeAvailable... == 0` and `release` reverts
   - at/after cliff: claimable includes linear accrual from start
3. **Full vest**: after `duration`, claimable == total.
4. **Aggregated release**: `release()` releases across multiple scheduleIds.
5. **Caps**:
   - per-address cap enforced across all tranches
   - total premint cap enforced

---

## 14. Forward-compatibility note (factory consolidation / 80% premint)

Today there are separate token variants (`DERC20` at 20% premint caps and `DERC2080` at 80%).

If you plan to **collapse factories into one** and optionally allow **80% pre-vesting**:

- Recommended approach: make premint caps **constructor immutables** rather than hard-coded constants:
  - `maxPreMintPerAddressWad`
  - `maxTotalPreMintWad`
- Enforce upper bounds (e.g., `<= 1 ether`) and default to `0.2 ether` for DERC20-like deployments.

This is explicitly **out of scope** for the core “multi-schedule vesting” change, but the vesting design above is compatible with that consolidation.

---

# Appendix A — Coder Implementation Checklist (v0.2.1)

This appendix is an implementation-oriented checklist for the coding agent.

## A1. File / contract strategy

- [ ] **Prefer** adding a new contract (e.g., `DERC20V2.sol` / `contract DERC20V2`) rather than modifying `DERC20.sol` in-place.
  - Rationale: preserves backwards compatibility for existing deployments + keeps existing factories/tests stable.
  - A new `TokenFactoryV2` can deploy `DERC20V2`.

## A2. Vesting types

- [ ] Add the schedule type:

  ```solidity
  struct VestingSchedule {
      uint64 cliff;    // seconds after vestingStart until claimable
      uint64 duration; // seconds after vestingStart until fully vested
  }
  ```

- [ ] Keep / reuse `VestingData { totalAmount, releasedAmount }`.

## A3. Storage layout

- [ ] Keep all existing non-vesting storage unchanged:
  - `pool`, `isPoolUnlocked`, `yearlyMintRate`, `currentYearStart`, `lastMintTimestamp`, `tokenURI`
  - Permit2 allowance override
  - `_update` pool-lock restriction

- [ ] Replace v1 vesting storage with multi-schedule storage:

  ```solidity
  uint256 public immutable vestingStart;       // set to block.timestamp in constructor
  uint256 public immutable vestedTotalAmount;  // sum of all allocations

  VestingSchedule[] public vestingSchedules;   // scheduleId = index

  mapping(address => mapping(uint256 => VestingData)) public vestingOf;

  // allow `release()` without args
  mapping(address => uint256[]) internal _scheduleIdsOf;
  mapping(address => mapping(uint256 => bool)) internal _hasSchedule;
  ```

- [ ] **Recommended (for cap enforcement & UX):** add a per-beneficiary total allocation mapping:

  ```solidity
  mapping(address => uint256) public totalAllocatedOf;
  ```

  This avoids O(n^2) cap checks in the constructor.

## A4. New errors & events

### Errors

- [ ] Add:

  ```solidity
  error NoReleasableAmount();
  error UnknownScheduleId(uint256 scheduleId);
  error InvalidSchedule(uint256 scheduleId);
  ```

- [ ] Keep existing errors where still relevant:
  - `ArrayLengthsMismatch`
  - `MaxPreMintPerAddressExceeded`
  - `MaxTotalPreMintExceeded`
  - `MaxTotalVestedExceeded`
  - `MaxYearlyMintRateExceeded`
  - `PoolLocked`, `MintingNotStartedYet`, `NoMintableAmount`, etc.

### Events

- [ ] Add:

  ```solidity
  event VestingScheduleCreated(uint256 indexed scheduleId, uint64 cliff, uint64 duration);
  event VestingAllocated(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);
  event TokensReleased(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);
  ```

## A5. Constructor checklist

### Inputs

- [ ] Update constructor params to include:
  - `VestingSchedule[] schedules_`
  - `address[] beneficiaries_`
  - `uint256[] scheduleIds_`
  - `uint256[] amounts_`

### Validation

- [ ] `yearlyMintRate_ <= MAX_YEARLY_MINT_RATE_WAD`
- [ ] Allocation arrays length match:
  - `beneficiaries_.length == scheduleIds_.length == amounts_.length`
- [ ] For each schedule `s`:
  - [ ] `s.duration > 0`
  - [ ] `s.cliff <= s.duration`
- [ ] For each allocation `i`:
  - [ ] `beneficiaries_[i] != address(0)`
  - [ ] `amounts_[i] > 0`
  - [ ] `scheduleIds_[i] < schedules_.length`

### Cap enforcement

- [ ] Compute limits (same as v1):

  ```solidity
  uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1 ether;
  uint256 maxTotalPreMint      = initialSupply * MAX_TOTAL_PRE_MINT_WAD / 1 ether;
  ```

- [ ] Enforce per-beneficiary cap **across all schedules**:
  - [ ] `totalAllocatedOf[beneficiary] += amount`
  - [ ] require `totalAllocatedOf[beneficiary] <= maxPreMintPerAddress`

- [ ] Enforce total premint cap:
  - [ ] `vestedTokens += amount`
  - [ ] require `vestedTokens <= maxTotalPreMint`
  - [ ] require `vestedTokens < initialSupply`

### State updates

- [ ] Set:
  - `vestingStart = block.timestamp`
  - `tokenURI = tokenURI_`
  - `yearlyMintRate = yearlyMintRate_`

- [ ] Store schedules:
  - [ ] push schedules into `vestingSchedules`
  - [ ] emit `VestingScheduleCreated(scheduleId, cliff, duration)` per schedule

- [ ] Apply allocations (aggregate duplicates allowed):

  ```solidity
  vestingOf[b][sid].totalAmount += amount;

  if (!_hasSchedule[b][sid]) {
      _hasSchedule[b][sid] = true;
      _scheduleIdsOf[b].push(sid);
  }
  emit VestingAllocated(b, sid, amount);
  ```

- [ ] Set `vestedTotalAmount = vestedTokens`.

### Minting

- [ ] If `vestedTokens > 0`, `_mint(address(this), vestedTokens)`.
- [ ] `_mint(recipient, initialSupply - vestedTokens)`.

## A6. Vesting math checklist

Implement an internal view helper (or inline logic) matching the spec:

- [ ] **Claim-gating cliff**: if `block.timestamp < vestingStart + cliff` => available = 0
- [ ] Linear vesting from start:
  - if `t >= start + duration`: vested = A
  - else vested = `A * (t - start) / duration`
- [ ] Available = `vested - released`

Suggested helper:

```solidity
function _available(address b, uint256 sid) internal view returns (uint256) {
    VestingData storage vd = vestingOf[b][sid];
    uint256 A = vd.totalAmount;
    if (A == 0) return 0;

    VestingSchedule memory s = vestingSchedules[sid];
    uint256 t = block.timestamp;
    uint256 start = vestingStart;

    if (t < start + s.cliff) return 0;

    uint256 vested = (t >= start + s.duration)
        ? A
        : (A * (t - start)) / s.duration;

    uint256 released = vd.releasedAmount;
    return vested > released ? vested - released : 0;
}
```

## A7. View functions checklist

- [ ] `vestingScheduleCount() -> vestingSchedules.length`
- [ ] `getVestingSchedule(uint256 sid) -> (cliff, duration)`
- [ ] `getScheduleIdsOf(address b) -> uint256[]`
- [ ] `computeAvailableVestedAmount(address b, uint256 sid) -> uint256` (calls `_available`)
- [ ] `computeAvailableVestedAmount(address b) -> uint256` (sum across `_scheduleIdsOf[b]`)

## A8. Release functions checklist

### `release(uint256 scheduleId)`

- [ ] Validate `scheduleId < vestingSchedules.length` (else `UnknownScheduleId`).
- [ ] `amt = _available(msg.sender, scheduleId)`
- [ ] `require(amt > 0, NoReleasableAmount())`
- [ ] `vestingOf[msg.sender][scheduleId].releasedAmount += amt`
- [ ] `_transfer(address(this), msg.sender, amt)`
- [ ] emit `TokensReleased(msg.sender, scheduleId, amt)`

### `release()` (all schedules)

**Important:** because release must revert on total==0, do not mutate state before the revert condition is known.

Recommended pattern (single recompute avoided):

- [ ] Load `ids = _scheduleIdsOf[msg.sender]`
- [ ] First pass: compute per-schedule available amounts into a memory array + sum total.
- [ ] `require(total > 0, NoReleasableAmount())`
- [ ] Second pass: apply state updates + emit per-schedule events for non-zero.
- [ ] Single `_transfer(address(this), msg.sender, total)` at the end.

### Optional: `releaseFor(beneficiary)`

- [ ] If included, anyone can call; funds always go to `beneficiary`.
- [ ] Same revert-on-zero semantics.

## A9. TokenFactory (v2) checklist

Because the encoded `data` changes, do not modify the existing `TokenFactory` in-place.

- [ ] Add `TokenFactoryV2` with:
  - decode:

    ```solidity
    (
      string name,
      string symbol,
      uint256 yearlyMintRate,
      VestingSchedule[] schedules,
      address[] beneficiaries,
      uint256[] scheduleIds,
      uint256[] amounts,
      string tokenURI
    ) = abi.decode(data, (...));
    ```

  - deploy `DERC20V2{salt:salt}(...)`.

- [ ] Update Airlock allowlist/registry as required by your deployment flow.

## A10. Tests checklist (minimum)

### Constructor & caps

- [ ] Deploy with 2 schedules + 3 allocations.
- [ ] Assert `vestingStart == block.timestamp`.
- [ ] Assert `balanceOf(address(token)) == vestedTotalAmount`.
- [ ] Assert per-address cap enforced **across schedules**.
- [ ] Assert total cap enforced.
- [ ] Reverts:
  - [ ] allocation array mismatch
  - [ ] invalid schedule (duration==0)
  - [ ] invalid schedule (cliff>duration)
  - [ ] scheduleId out of range

### Cliff gating

- [ ] Warp to `start + cliff - 1`:
  - `computeAvailableVestedAmount(beneficiary, sid) == 0`
  - `release(sid)` reverts `NoReleasableAmount`
- [ ] Warp to `start + cliff`:
  - available > 0 (if cliff > 0 and duration > 0)

### Linear vesting

- [ ] Warp to `start + duration/4`, claim and assert ~25%.
- [ ] Warp to `start + duration/2`, claim and assert ~50% total.
- [ ] Warp to `start + duration`, claim and assert 100%.

### Multi-tranche + multi-schedule

- [ ] Same beneficiary with 2 schedules:
  - `release()` claims both (sum)
  - `release(sid)` only claims one

### Revert-on-zero

- [ ] Calling `release()` when nothing claimable reverts `NoReleasableAmount`.
- [ ] Calling `release(sid)` when nothing claimable reverts.

### Invariants

- [ ] For each (beneficiary, sid): `releasedAmount <= totalAmount`.
- [ ] Total released across all beneficiaries never exceeds `vestedTotalAmount`.

## A11. Gas / style notes

- [ ] Use `unchecked { ++i; }` in loops where safe.
- [ ] Prefer a single `_transfer` in `release()` to reduce gas.
- [ ] Emitting per-schedule `TokensReleased` events is recommended for transparency.

