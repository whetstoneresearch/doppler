# Anoncoin Beneficiaries Fix - Step by Step

**Error:** `InvalidProtocolOwnerBeneficiary()` (signature `0xdfa06864`)

## Root Cause

The contract validation requires the **Airlock owner** to be in the beneficiaries list with at least 5% shares. You're currently passing the **Airlock contract address** instead.

## Current (WRONG) Transaction Data

From your Telegram message 478480-478485, the transaction shows:

```
Beneficiary 2: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12 (50000000000000000 shares = 5%)
```

This is the **Airlock CONTRACT**, not the owner!

## Required Fix

**Airlock Contract:** `0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12` ❌
**Airlock Owner (CORRECT):** `0x21E2ce70511e4FE542a97708e89520471DAa7A66` ✅

## Step-by-Step Solution

### 1. Fetch Protocol Owner Dynamically

```typescript
import { airlockAbi } from '@whetstone-research/doppler-sdk-alpha'

// Get the Airlock owner address for Monad Mainnet
const protocolOwner = await publicClient.readContract({
  address: '0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12', // Airlock contract
  abi: airlockAbi,
  functionName: 'owner'
}) as Address

console.log('Protocol Owner:', protocolOwner)
// Should log: 0x21E2ce70511e4FE542a97708e89520471DAa7A66
```

### 2. Create Beneficiaries Array with Correct Address

```typescript
const beneficiaries = [
    {
        beneficiary: protocolOwner, // ✅ Use 0x21E2... NOT 0x660e...
        shares: WAD / 20n // 5%
    },
    {
        beneficiary: fromAddress, // Your deployer
        shares: WAD / 2n // 50%
    },
    {
        beneficiary: platformPublicKey, // Your partner
        shares: (WAD * 45n) / 100n // 45%
    },
]

// Verify total shares
const totalShares = beneficiaries.reduce((sum, b) => sum + b.shares, 0n)
console.log('Total shares:', totalShares === WAD ? '✅ Correct' : '❌ Wrong')

// SDK will automatically sort these by address
```

### 3. Build with Correct Parameters

```typescript
const builder = sdk
    .buildMulticurveAuction()
    .tokenConfig({
        type: 'standard',
        name: 'YourToken',
        symbol: 'TOKEN',
        tokenURI: 'your-uri'
    })
    .saleConfig({
        initialSupply: 1_000_000_000n * WAD,
        numTokensToSell: 1_000_000_000n * WAD,
        numeraire: wmonAddress
    })
    .withMulticurveAuction({
        fee: 20000,
        tickSpacing: 60,
        curves: yourCurves,
        beneficiaries: beneficiaries // ✅ Use 'beneficiaries', not 'lockableBeneficiaries'
    })
    .withSchedule({ startTime: yourStartTime })
    .withGovernance({ type: 'default' })
    .withMigration({ type: 'noOp' }) // Required when using beneficiaries
    .withUserAddress(yourAddress)
    .withV4ScheduledMulticurveInitializer(addresses.v4ScheduledMulticurveInitializer)
    .withNoOpMigrator(addresses.noOpMigrator)

const params = builder.build()
```

### 4. Verify Before Sending

```typescript
// Check the params BEFORE creating the transaction
console.log('Beneficiaries in params:', params.pool.beneficiaries)

// Expected output should include:
// { beneficiary: '0x21E2ce70511e4FE542a97708e89520471DAa7A66', shares: 50000000000000000n }
```

### 5. Double-Check Transaction Data

After building the transaction but BEFORE sending:

```typescript
const createParams = sdk.factory.encodeCreateMulticurveParams(params)

// Decode the poolInitializerData to verify beneficiaries
console.log('Pool Initializer:', createParams.poolInitializer)
console.log('Pool Initializer Data:', createParams.poolInitializerData)

// The beneficiaries should be embedded in the poolInitializerData
// Verify it contains 0x21e2... not 0x660e...
if (createParams.poolInitializerData.toLowerCase().includes('660eaa')) {
  throw new Error('❌ WRONG: Still using Airlock contract address!')
}
if (createParams.poolInitializerData.toLowerCase().includes('21e2ce')) {
  console.log('✅ CORRECT: Using Airlock owner address')
}
```

## Common Mistakes to Avoid

1. ❌ Using `lockableBeneficiaries` instead of `beneficiaries` in `withMulticurveAuction()`
2. ❌ Using Airlock contract address (`0x660e...`) instead of owner (`0x21E2...`)
3. ❌ Hardcoding the protocol owner (it might change per chain)
4. ❌ Forgetting to set `.withMigration({ type: 'noOp' })` when using beneficiaries
5. ❌ Not verifying the transaction data before sending

## Validation Checklist

Before sending the transaction:

- [ ] Fetched protocol owner dynamically using `airlock.owner()`
- [ ] Protocol owner address is `0x21E2ce70511e4FE542a97708e89520471DAa7A66`
- [ ] Protocol owner has exactly 5% shares (50000000000000000n)
- [ ] Total shares sum to WAD (1000000000000000000n)
- [ ] Using `beneficiaries` key (not `lockableBeneficiaries`)
- [ ] Using `.withMigration({ type: 'noOp' })`
- [ ] Verified transaction data contains `21e2ce` not `660eaa`

## Testing

To test without spending gas:

```typescript
// Simulate the transaction first
const { asset, pool } = await sdk.factory.simulateCreateMulticurve(params)
console.log('Simulation successful!')
console.log('Asset:', asset)
console.log('Pool:', pool)
```

If simulation passes, the real transaction should work.

## Reference

- Airlock Contract (Monad Mainnet): `0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12`
- Airlock Owner (Monad Mainnet): `0x21E2ce70511e4FE542a97708e89520471DAa7A66`
- Error Code: `0xdfa06864` = `InvalidProtocolOwnerBeneficiary()`
- Contract Validation: `src/types/BeneficiaryData.sol:83`
