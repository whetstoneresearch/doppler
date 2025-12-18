#!/usr/bin/env ts-node
/**
 * Check if an Anoncoin pool is locked (has beneficiaries)
 *
 * Usage: ts-node check-pool-status.ts
 */

import { createPublicClient, http, parseAbi } from 'viem';

// Monad Mainnet config
const MONAD_MAINNET_RPC = 'https://rpc.monad.xyz';
const CHAIN_ID = 143;

// Anoncoin's BLIND14 token
const ASSET_ADDRESS = '0x8f27B549f8CA084dac93e4808DE4e81fD6ff8A9B';

// UniswapV4ScheduledMulticurveInitializer address from deployments/143.md
const INITIALIZER_ADDRESS = '0xce3099b2f07029b086e5e92a1573c5f5a3071783';

const client = createPublicClient({
  transport: http(MONAD_MAINNET_RPC),
});

const initializerAbi = parseAbi([
  'function getState(address asset) view returns (tuple(address numeraire, tuple(address beneficiary, uint96 shares)[] beneficiaries, tuple(int24 tickLower, int24 tickUpper, uint128 liquidity)[] positions, uint8 status, tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, int24 farTick))',
  'function getBeneficiaries(address asset) view returns (tuple(address beneficiary, uint96 shares)[])',
]);

async function checkPoolStatus() {
  console.log('Checking Anoncoin BLIND14 pool status...\n');
  console.log(`Chain: Monad Mainnet (${CHAIN_ID})`);
  console.log(`Asset: ${ASSET_ADDRESS}`);
  console.log(`Initializer: ${INITIALIZER_ADDRESS}\n`);

  try {
    // Method 1: Get beneficiaries
    const beneficiaries = await client.readContract({
      address: INITIALIZER_ADDRESS as `0x${string}`,
      abi: initializerAbi,
      functionName: 'getBeneficiaries',
      args: [ASSET_ADDRESS as `0x${string}`],
    });

    console.log('=== BENEFICIARIES ===');
    if (beneficiaries && beneficiaries.length > 0) {
      console.log(`✅ Pool HAS beneficiaries (Locked): ${beneficiaries.length} beneficiary(ies)`);
      console.log('\nBeneficiaries:');
      beneficiaries.forEach((b: any, i: number) => {
        console.log(`  ${i + 1}. ${b.beneficiary} - ${b.shares} shares`);
      });
      console.log('\n⚠️  This pool CANNOT be migrated (status = Locked)');
      console.log('⚠️  Fees are collected via FeesManager.collectFees()');
    } else {
      console.log(`❌ Pool has NO beneficiaries (Initialized)`);
      console.log('\n✅ This pool CAN be migrated via Airlock.migrate()');
      console.log('✅ Fees will be extracted during migration and sent to integrator/protocol');
    }

    // Method 2: Get full state including status
    const state = await client.readContract({
      address: INITIALIZER_ADDRESS as `0x${string}`,
      abi: initializerAbi,
      functionName: 'getState',
      args: [ASSET_ADDRESS as `0x${string}`],
    });

    console.log('\n=== POOL STATUS ===');
    const statusNames = ['Uninitialized', 'Initialized', 'Locked', 'Exited'];
    console.log(`Status: ${statusNames[state.status]} (${state.status})`);
    console.log(`Numeraire: ${state.numeraire}`);
    console.log(`Positions: ${state.positions.length}`);
    console.log(`Far Tick: ${state.farTick}`);

  } catch (error) {
    console.error('Error checking pool status:', error);
    throw error;
  }
}

checkPoolStatus().catch(console.error);
