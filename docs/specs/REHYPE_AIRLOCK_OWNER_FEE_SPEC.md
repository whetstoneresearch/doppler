# Rehype Doppler Hook: Airlock Owner Fee Specification

## Overview

This specification describes changes to the RehypeDopplerHook to implement a dedicated 5% fee allocation for the airlock owner, separate from the beneficiary fee distribution system.

## Current Behavior

### Fee Collection Flow

1. On each swap, `_collectSwapFees()` calculates the fee:
   ```
   feeAmount = outputAmount * customFee / MAX_SWAP_FEE
   ```

2. Fees accumulate in `getHookFees[poolId].fees0` and `getHookFees[poolId].fees1`

3. When fees exceed `EPSILON` (1e6), `_onSwap` distributes them according to `FeeDistributionInfo`:
   - `assetBuybackPercentWad` → swapped to asset, sent to `buybackDst`
   - `numeraireBuybackPercentWad` → swapped to numeraire, sent to `buybackDst`
   - `lpPercentWad` → rebalanced and added as LP
   - Remainder → accumulated in `beneficiaryFees0/1`

4. `collectFees(asset)` transfers accumulated `beneficiaryFees` to `buybackDst`

### Current Airlock Owner Handling

- Airlock owner **must** be included in the beneficiaries array
- Minimum share requirement: `MIN_PROTOCOL_OWNER_SHARES = 5%` (0.05e18)
- Airlock owner receives their proportional share when beneficiary fees are distributed
- Enforced in `BeneficiaryData.sol:storeBeneficiaries()`

### Problems with Current Approach

1. Airlock owner fee is diluted through the `beneficiaryPercentWad` distribution
2. Airlock owner competes with other beneficiaries for fee allocation
3. No guaranteed fixed percentage of the raw swap fee for airlock owner

## Proposed Behavior

### New Fee Collection Flow

1. On each swap, `_collectSwapFees()` calculates the fee:
   ```
   feeAmount = outputAmount * customFee / MAX_SWAP_FEE
   ```

2. **NEW**: Immediately take 5% of `feeAmount` for airlock owner:
   ```
   airlockOwnerFee = feeAmount * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR
   remainingFee = feeAmount - airlockOwnerFee
   ```

3. `airlockOwnerFee` accumulates in new storage: `getHookFees[poolId].airlockOwnerFees0/1`

4. `remainingFee` (95% of original) follows the existing distribution flow

5. **NEW**: `claimAirlockOwnerFees(asset)` allows airlock owner to claim accumulated fees

### Key Changes

| Aspect | Current | Proposed |
|--------|---------|----------|
| Airlock owner fee source | Portion of `beneficiaryPercentWad` | 5% of raw custom fee |
| Fee timing | After distribution | Upfront, before distribution |
| Claim mechanism | Via `collectFees()` to `buybackDst` | Dedicated `claimAirlockOwnerFees()` |
| Beneficiary requirement | Airlock owner must be beneficiary | Airlock owner no longer required in beneficiaries |

## Technical Specification

### Constants

```solidity
/// @dev Airlock owner fee in basis points (5% = 500 BPS)
uint256 constant AIRLOCK_OWNER_FEE_BPS = 500;

/// @dev Basis points denominator
uint256 constant BPS_DENOMINATOR = 10_000;
```

### Storage Changes

#### `src/types/RehypeTypes.sol`

```solidity
struct HookFees {
    uint128 fees0;
    uint128 fees1;
    uint128 beneficiaryFees0;
    uint128 beneficiaryFees1;
    uint128 airlockOwnerFees0;    // NEW
    uint128 airlockOwnerFees1;    // NEW
    uint24 customFee;
}
```

No additional storage mappings are needed. The airlock owner is fetched dynamically via `MIGRATOR.airlock().owner()` at claim time, ensuring that ownership transfers are always reflected without stale per-pool state.

### Function Changes

#### `_collectSwapFees()`

Take 5% for airlock owner before returning:

```solidity
function _collectSwapFees(
    IPoolManager.SwapParams memory params,
    BalanceDelta delta,
    PoolKey memory key,
    PoolId poolId
) internal returns (Currency feeCurrency, int128 feeDelta) {
    // ... existing fee calculation ...
    
    uint256 feeAmount = FullMath.mulDiv(uint256(outputAmount), getHookFees[poolId].customFee, MAX_SWAP_FEE);
    
    // NEW: Calculate airlock owner fee (5% of total fee)
    uint256 airlockOwnerFee = FullMath.mulDiv(feeAmount, AIRLOCK_OWNER_FEE_BPS, BPS_DENOMINATOR);
    uint256 remainingFee = feeAmount - airlockOwnerFee;
    
    // ... existing balance check ...
    
    poolManager.take(feeCurrency, address(this), feeAmount);
    
    // NEW: Accumulate airlock owner fees
    if (feeCurrency == key.currency0) {
        getHookFees[poolId].airlockOwnerFees0 += uint128(airlockOwnerFee);
        getHookFees[poolId].fees0 += uint128(remainingFee);
    } else {
        getHookFees[poolId].airlockOwnerFees1 += uint128(airlockOwnerFee);
        getHookFees[poolId].fees1 += uint128(remainingFee);
    }
    
    return (feeCurrency, int128(uint128(feeAmount)));
}
```

#### New Function: `claimAirlockOwnerFees()`

```solidity
/// @notice Claims accumulated airlock owner fees for a pool
/// @param asset Asset address to identify the pool
/// @return fees0 Amount of currency0 claimed
/// @return fees1 Amount of currency1 claimed
function claimAirlockOwnerFees(address asset) external returns (uint128 fees0, uint128 fees1) {
    address airlockOwner = MIGRATOR.airlock().owner();
    require(msg.sender == airlockOwner, SenderNotAirlockOwner());

    (address token0, address token1) = MIGRATOR.getPair(asset);
    (, PoolKey memory poolKey,,,,,,) = MIGRATOR.getAssetData(token0, token1);
    PoolId poolId = poolKey.toId();

    fees0 = getHookFees[poolId].airlockOwnerFees0;
    fees1 = getHookFees[poolId].airlockOwnerFees1;

    if (fees0 > 0) {
        getHookFees[poolId].airlockOwnerFees0 = 0;
        poolKey.currency0.transfer(msg.sender, fees0);
    }
    if (fees1 > 0) {
        getHookFees[poolId].airlockOwnerFees1 = 0;
        poolKey.currency1.transfer(msg.sender, fees1);
    }
}
```

The airlock owner is resolved dynamically via `MIGRATOR.airlock().owner()` rather than stored per-pool. This ensures that if ownership of the Airlock contract is transferred, the new owner can claim fees from all pools — there is no stale state to manage.

### New Error

```solidity
/// @notice Thrown when the sender is not the airlock owner
error SenderNotAirlockOwner();
```

### Beneficiary Validation Changes

**Decision**: Keep existing beneficiary validation unchanged. The airlock owner can still be a beneficiary (receiving portion of `beneficiaryPercentWad`) AND receive the 5% upfront fee. This provides flexibility without breaking existing behavior and maintains backward compatibility.

## Events

```solidity
/// @notice Emitted when airlock owner claims fees
/// @param poolId The pool from which fees were claimed
/// @param airlockOwner The address that received the fees
/// @param fees0 Amount of currency0 claimed
/// @param fees1 Amount of currency1 claimed
event AirlockOwnerFeesClaimed(
    PoolId indexed poolId,
    address indexed airlockOwner,
    uint128 fees0,
    uint128 fees1
);
```

## View Functions

Airlock owner fees can be queried directly from the `getHookFees` mapping via `getHookFees[poolId].airlockOwnerFees0` and `getHookFees[poolId].airlockOwnerFees1`.

## Example Fee Flow

Given:
- Swap output: 1000 tokens
- Custom fee: 1% (10,000 in fee units)
- Fee distribution: 25% asset buyback, 25% numeraire buyback, 25% beneficiary, 25% LP

**Current behavior:**
```
Total fee collected: 10 tokens
→ Asset buyback: 2.5 tokens
→ Numeraire buyback: 2.5 tokens  
→ LP reinvestment: 2.5 tokens
→ Beneficiary fees: 2.5 tokens (airlock owner gets their share of this)
```

**Proposed behavior:**
```
Total fee collected: 10 tokens
→ Airlock owner (5% upfront): 0.5 tokens
→ Remaining for distribution: 9.5 tokens
  → Asset buyback: 2.375 tokens
  → Numeraire buyback: 2.375 tokens
  → LP reinvestment: 2.375 tokens
  → Beneficiary fees: 2.375 tokens
```

## Test Cases

1. **Fee collection**: Verify 5% goes to `airlockOwnerFees`, 95% to `fees`
2. **Claim authorization**: Only current airlock owner can call `claimAirlockOwnerFees()`
3. **Claim transfer**: Fees transferred correctly and storage reset
4. **Zero fees**: Handle case when no fees accumulated
5. **Multiple swaps**: Fees accumulate correctly across swaps
6. **Both directions**: Fees accumulate in correct currency based on swap direction
7. **Ownership transfer**: After airlock ownership transfer, new owner can claim all unclaimed fees

## Migration Considerations

- Existing pools will have `airlockOwnerFees0/1 = 0` — no fees to claim until new swaps occur
- No per-pool owner storage means no stale state to migrate
- The airlock owner is always resolved dynamically, so ownership transfers take effect immediately across all pools

## Security Considerations

1. **Reentrancy**: `claimAirlockOwnerFees()` follows checks-effects-interactions pattern (storage zeroed before transfer)
2. **Access control**: Only the current airlock owner (resolved dynamically) can claim fees
3. **Ownership transfer**: If airlock ownership is transferred, the new owner gains access to all unclaimed fees across all pools. The previous owner loses access. This is by design — the airlock owner role is a protocol-level authority.
4. **Overflow**: Using uint128 for fee accumulation; may need overflow checks for high-volume pools
5. **Rounding**: Using FullMath.mulDiv for safe multiplication/division

## Files to Modify

| File | Changes |
|------|---------|
| `src/types/RehypeTypes.sol` | Add `airlockOwnerFees0/1` to `HookFees` |
| `src/dopplerHooks/RehypeDopplerHookMigrator.sol` | Modify `_collectSwapFees`, add `claimAirlockOwnerFees()` |
| `test/unit/dopplerHooks/rehypeHookMigrator/RehypeDopplerHookMigrator.t.sol` | Add unit tests |
| `test/integration/DopplerHookMigratorIntegration.t.sol` | Add integration tests |
