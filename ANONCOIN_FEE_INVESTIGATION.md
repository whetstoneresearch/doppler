# Anoncoin Fee Investigation Summary

**Date:** 2025-11-24
**Issue:** Integrator and protocol fees showing as 0 despite trading activity

## The Good News
Fees ARE accruing, they're just not visible where Anoncoin is looking.

## How Fee Mechanism Works for Scheduled-Multicurve Pools

### 1. During Trading (Pre-Migration)
- Swap fees accumulate in the Uniswap V4 LP positions held by the `UniswapV4ScheduledMulticurveInitializer` contract
- The indexer fields `totalFee0` and `totalFee1` remain at `0` - **they're only populated during migration**
- **Protocol and integrator fees are NOT separated out yet** - all fees sit in the LP positions as undistributed fee growth

### 2. Fee Distribution Happens at Migration
When `Airlock.migrate()` is called:
1. Triggers `exitLiquidity()` on the initializer (Airlock.sol:209)
2. `exitLiquidity()` calls `_burn()` which extracts both liquidity AND accumulated fees from positions (UniswapV4MulticurveInitializer.sol:245)
3. The Airlock's `_handleFees()` function (Airlock.sol:211-212) then:
   - Calculates protocol fees: `max(fees/20, (balance-fees)/1000)` capped at `fees/5` (5% of trading fees OR 0.1% of proceeds, capped at 20%)
   - Allocates remaining fees to the integrator
   - Stores them in `getProtocolFees` and `getIntegratorFees` mappings

### 3. Checking If Fees Are Accruing
Since fees aren't distributed until migration, they **cannot** check:
- ❌ Indexer `totalFee0`/`totalFee1` fields
- ❌ `Airlock.getIntegratorFees()` or `getProtocolFees()`

They **can** check:
- ✅ V4 PoolManager positions directly to see fee growth
- ✅ If their pool has beneficiaries (status == "Locked"), call `collectFees(poolId)` on the FeesManager
- ✅ Test full lifecycle including migration on testnet

## Anoncoin's Pool Details
- **Token:** BLIND14 (0x8f27B549f8CA084dac93e4808DE4e81fD6ff8A9B)
- **Pool:** 0x03dd5e8d8331739c255d50e23e98fca8f3d7a25e61b9eb062b69774563b3a5e3
- **Hook:** 0x580ca49389d83b019d07e17e99454f2f218e2dc0 (UniswapV4ScheduledMulticurveInitializerHook)
- **Initializer:** 0xce3099b2f07029b086e5e92a1573c5f5a3071783 (UniswapV4ScheduledMulticurveInitializer)
- **Chain:** Monad public mainnet (chainId: 143)
- **Pool Type:** scheduled-multicurve
- **Pool Fee:** 20000 (2%)
- **Beneficiaries:** None (confirmed via `getBeneficiaries()` call)
- **Status:** ✅ **Initialized** (NOT Locked)
- **Can Migrate:** ✅ **YES** - migration will happen when bonding curve completes

## Pool Info from Indexer
```json
{
  "totalFee0": "0",
  "totalFee1": "0",
  "fee": 20000,
  "type": "scheduled-multicurve"
}
```

## Why This is Expected Behavior
The `totalFee0: "0"` and `totalFee1: "0"` they see are **expected pre-migration**. These fields only get populated when:
1. The pool is migrated from the bonding curve to a regular Uniswap V4 pool
2. The `exitLiquidity()` function burns all positions and extracts fees
3. The Airlock distributes fees to protocol and integrator

## How to Check if a Pool is Locked (Has Beneficiaries)

Pools can be in two states regarding migration:
- **Initialized** (no beneficiaries): Can be migrated via `Airlock.migrate()`, fees distributed at migration
- **Locked** (has beneficiaries): CANNOT be migrated, fees collected via `FeesManager.collectFees()`

To check a pool's status:

```bash
# Check beneficiaries (if empty array, pool is NOT locked)
cast call <INITIALIZER_ADDRESS> \
  "getBeneficiaries(address)(tuple(address,uint96)[])" \
  <ASSET_ADDRESS> \
  --rpc-url <RPC_URL>

# For Anoncoin's BLIND14 pool:
cast call 0xce3099b2f07029b086e5e92a1573c5f5a3071783 \
  "getBeneficiaries(address)(tuple(address,uint96)[])" \
  0x8f27B549f8CA084dac93e4808DE4e81fD6ff8A9B \
  --rpc-url https://rpc.monad.xyz

# Result: [] (empty = NOT locked, can migrate)
```

**Pool Status Implications:**
- ✅ **Initialized** (no beneficiaries):
  - Fees accumulate in LP positions
  - Visible in Airlock after migration via `getIntegratorFees()`/`getProtocolFees()`
  - Can call `Airlock.collectIntegratorFees()` after migration
- ❌ **Locked** (has beneficiaries):
  - Fees collected periodically via `FeesManager.collectFees(poolId)`
  - NO migration possible (exitLiquidity requires status == Initialized)
  - Fees distributed to beneficiaries over time

See code at `UniswapV4MulticurveInitializer.sol:188` and `UniswapV4MulticurveInitializer.sol:234`

## Recommendation
To verify fees are working before going live:
1. Test a full lifecycle including migration on testnet
2. Check the positions directly in the PoolManager contract for fee growth
3. If using beneficiaries/locked pools, test the `collectFees()` mechanism

## Code References
- Fee handling during migration: `src/Airlock.sol:211-212`
- Exit liquidity and fee extraction: `src/UniswapV4MulticurveInitializer.sol:218-253`
- Fee calculation logic: `src/Airlock.sol:238-252`
- Position burning: `src/base/MiniV4Manager.sol:111-119`
