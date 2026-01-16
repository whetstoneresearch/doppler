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

