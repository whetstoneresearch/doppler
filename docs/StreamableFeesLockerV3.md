# StreamableFeesLockerV3

| Module Name                  | Type         | Status    |
| ---------------------------- | ------------ | --------- |
| `StreamableFeesLockerV3.sol` | `Standalone` | `Testnet` |

## Overview

`StreamableFeesLockerV3` locks migrated Uniswap V4 liquidity for a configured duration while allowing the pool's fee beneficiaries to collect accrued LP fees during the lock period. It is the active locker used by `DopplerHookMigrator`.

V3 keeps the external integration shape used by `StreamableFeesLockerV2`: approved migrators transfer token balances into the locker, then call `lock` with a `PoolKey`, lock duration, unlock recipient, beneficiaries, and position ranges. The key behavioral change is how liquidity is handled at unlock. V2 burned its internal liquidity positions and sent the withdrawn underlying currencies to the recipient. V3 mints Uniswap V4 `PositionManager` NFTs, holds those NFTs during the lock, and transfers the still-liquid NFTs to the recipient when the lock expires.

This means the recipient receives control of the liquidity position itself after unlock and can manage liquidity or claim fees directly through the Uniswap V4 `PositionManager`.

## Architecture

V3 depends on:

- `IPoolManager`: the Uniswap V4 pool manager for the target pool.
- `PositionManager`: the Uniswap V4 periphery position manager used to mint, collect fees from, and transfer position NFTs.
- `FeesManager`: shared fee accounting and beneficiary-claim logic.
- `Ownable`: owner-only migrator approval and revocation.

The locker stores one stream per `PoolId`. Each stream records:

- the `PoolKey`,
- the unlock recipient,
- the lock start timestamp,
- the lock duration,
- whether the stream has already unlocked,
- the beneficiary list,
- the `PositionManager` token IDs minted and held by the locker.

## Lock Flow

Only approved migrators can call `lock`.

The expected integration flow is:

1. A migrator creates or initializes the Uniswap V4 pool.
2. The migrator transfers the pool currencies to the locker.
3. The migrator calls `lock(poolKey, lockDuration, recipient, beneficiaries, positions)`.
4. The locker stores beneficiary shares through `FeesManager`.
5. The locker mints one `PositionManager` NFT for each supplied `Position`.
6. The locker records the minted token IDs against the pool stream.

The locker uses its full token balances as the maximum amounts for minting. Any currency not consumed by the `PositionManager` mint remains in the locker as leftover balance. V3 does not withdraw liquidity at unlock, so post-unlock recipients should not expect to receive the underlying token balances that remain as dust in the locker.

For ERC20 currencies, the locker approves the `PositionManager` through Permit2 before minting:

- it checks the ERC20 allowance from the locker to Permit2,
- if needed, it grants Permit2 a max ERC20 allowance,
- it grants the `PositionManager` a Permit2 allowance for the required amount with max expiration.

Native currency pools are supported. When either pool currency is native ETH, the locker forwards its native balance into `PositionManager.modifyLiquidities` and sweeps unused native balance back to itself.

## Fee Collection

Anyone can call `collectFees(poolId)`.

Before unlock, V3 collects fees from every locked position NFT by calling the `PositionManager` with zero-liquidity `DECREASE_LIQUIDITY` actions followed by `TAKE_PAIR`. This collects accrued fees without reducing position liquidity.

Collected fees are accounted through `FeesManager`:

- global cumulative fees are updated for the pool,
- if the caller is a beneficiary, the caller's claimable share is released immediately,
- other beneficiaries' shares remain claimable for later calls,
- beneficiaries can move their future fee entitlement with `updateBeneficiary(poolId, newBeneficiary)`.

After a stream has unlocked, `collectFees(poolId)` no longer collects fees from the transferred NFTs and returns zero newly collected fees. At that point, the NFT owner controls the positions and claims future fees directly through the `PositionManager`.

## Unlock Flow

Unlock happens opportunistically inside `collectFees(poolId)`. If the current timestamp is at least `startDate + lockDuration`, and the stream recipient is not `DEAD_ADDRESS`, the locker:

1. collects any pending fees from the still-locked position NFTs,
2. marks the stream as unlocked,
3. transfers each `PositionManager` NFT to the recipient,
4. emits `Unlock(poolId, recipient)`.

The transfer uses regular ERC721 `transferFrom`, not `safeTransferFrom`. Recipients do not need to implement `onERC721Received`. This is intentional because governance timelocks and other operational recipients may not implement the ERC721 receiver callback.

V3 does not burn positions or withdraw liquidity during unlock. Liquidity remains in the Uniswap V4 positions, and the recipient receives the position NFTs with liquidity intact.

## Permanent Locks

If the recipient is `DEAD_ADDRESS`, the stream is treated as permanently locked:

- `Lock` emits an unlock date of `0`,
- `collectFees` continues to collect and stream fees to beneficiaries,
- position NFTs are never transferred out by the locker,
- `isUnlocked` remains false.

Other invalid or non-operational recipient addresses are not special-cased. If a non-`DEAD_ADDRESS` recipient cannot practically manage NFTs after a normal `transferFrom`, the position may be difficult or impossible to operate, but the locker will still transfer the NFTs once the lock expires.

## Permissions

### Owner

The owner can:

- approve migrators with `approveMigrator`,
- revoke migrators with `revokeMigrator`.

The owner is also guaranteed the minimum protocol-owner fee share enforced by `FeesManager` and `BeneficiaryData`.

### Migrators

Approved migrators can call `lock`. A pool can only be locked once; a second lock for the same `PoolId` reverts with `StreamAlreadyStarted`.

### Beneficiaries

Beneficiaries can:

- call `collectFees(poolId)` to trigger collection and receive their current share,
- call `updateBeneficiary(poolId, newBeneficiary)` to transfer their fee-share entitlement.

`collectFees` is permissionless, but only beneficiaries receive released fees from that call.

## Public Surface

### `lock`

```solidity
function lock(
    PoolKey memory poolKey,
    uint32 lockDuration,
    address recipient,
    BeneficiaryData[] calldata beneficiaries,
    Position[] calldata positions
) external;
```

Locks liquidity for a pool by minting and custodying `PositionManager` NFTs. Callable only by approved migrators.

### `collectFees`

```solidity
function collectFees(PoolId poolId) external returns (uint128 fees0, uint128 fees1);
```

Collects fees before unlock, updates fee accounting, releases the caller's beneficiary share if applicable, and triggers unlock if the lock duration has elapsed.

### `getTokenIds`

```solidity
function getTokenIds(PoolId poolId) external view returns (uint256[] memory);
```

Returns the `PositionManager` token IDs associated with a pool stream.

### `streams`

```solidity
mapping(PoolId poolId => StreamData) public streams;
```

Returns stream metadata. Solidity's autogenerated getter exposes static fields; use `getTokenIds` for the dynamic token ID array.

## Events

- `Lock(poolId, beneficiaries, unlockDate)`: emitted when positions are minted and locked.
- `Unlock(poolId, recipient)`: emitted when position NFTs are transferred to the unlock recipient.
- `MigratorApproval(migrator, approval)`: emitted when migrator approval changes.
- `Collect(poolId, fees0, fees1)`: inherited from `FeesManager`, emitted on fee collection.
- `Release(poolId, beneficiary, fees0, fees1)`: inherited from `FeesManager`, emitted when a beneficiary receives fees.
- `UpdateBeneficiary(poolId, oldBeneficiary, newBeneficiary)`: inherited from `FeesManager`, emitted when a beneficiary transfers fee entitlement.

## Integration Notes

`DopplerHookMigrator` transfers both pool currencies to the locker, then calls `lock` with the computed single-sided position ranges. The migrator does not need to receive or manage `PositionManager` NFTs.

Recipients should be prepared to receive standard ERC721 transfers. Because V3 uses `transferFrom`, contract recipients do not need an ERC721 receiver callback, but they must have an operational path to manage or transfer the received NFTs later.

For Doppler ERC20 V1 assets, the token implementation gives canonical Permit2 an infinite allowance by default. V3 still handles non-canonical or test Permit2 deployments by approving Permit2 for `type(uint256).max` when the observed allowance is insufficient.

## V2 Differences

The user-facing and integrator-facing lock flow is intended to remain the same as V2, with one major unlock difference.

| Area                        | V2                                                                         | V3                                                                   |
| --------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Lock caller                 | Approved migrator                                                          | Same                                                                 |
| Migrator inputs             | `PoolKey`, duration, recipient, beneficiaries, positions                   | Same                                                                 |
| Fee claims before unlock    | Beneficiaries claim streamed fees                                          | Same                                                                 |
| Liquidity representation    | Internal V4 liquidity managed through pool manager helpers                 | `PositionManager` ERC721 NFTs minted and held by locker              |
| Unlock trigger              | `collectFees` after lock duration                                          | Same                                                                 |
| Unlock result               | Burns/withdraws locked liquidity and transfers raw currencies to recipient | Transfers position NFTs to recipient with liquidity intact           |
| Post-unlock fee claims      | Recipient has raw currencies, no remaining locked position                 | Recipient owns NFTs and claims future fees through `PositionManager` |
| Permanent lock sentinel     | `DEAD_ADDRESS`                                                             | Same                                                                 |
| Contract recipient callback | Not applicable to raw currency transfer                                    | Not required because V3 uses ERC721 `transferFrom`                   |

V3 therefore preserves the same broad lifecycle as V2: lock, stream fees during the lock, unlock through `collectFees`. The intentional behavioral change is that unlock transfers liquidity control instead of withdrawing liquidity.
