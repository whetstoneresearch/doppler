# Auth-Bridge Oracle Integration Guide

This guide explains how to wire the Auth-Bridge hook + oracle for a new pool.

## Contracts

- Hook: `AuthBridgeDopplerHook`
- Oracle: `AuthBridgeOracle`
- Interface: `IAuthBridgeOracle`

The hook is a thin orchestrator. All signature verification, nonce tracking,
deadline checks, executor binding, and signer allowlist enforcement live in the oracle.

## Initialization Flow

1. Deploy the hook and oracle:

```solidity
AuthBridgeDopplerHook hook = new AuthBridgeDopplerHook(address(initializer));
AuthBridgeOracle oracle = new AuthBridgeOracle(address(hook));
```

2. Enable the hook on the initializer:

```solidity
initializer.setDopplerHookState(
    [address(hook)],
    [ON_INITIALIZATION_FLAG | ON_SWAP_FLAG]
);
```

3. Encode oracle init data (single immutable signer):

```solidity
AuthBridgeOracleInitData memory oracleInit = AuthBridgeOracleInitData({
    platformSigner: platformSigner
});

AuthBridgeInitData memory hookInit = AuthBridgeInitData({
    oracle: address(oracle),
    oracleData: abi.encode(oracleInit)
});
```

4. Pass `hookInit` during pool creation:

```solidity
InitData memory initData = InitData({
    // ...other fields...
    dopplerHook: address(hook),
    onInitializationDopplerHookCalldata: abi.encode(hookInit),
    graduationDopplerHookCalldata: new bytes(0)
});
```

## Swap Authorization

Swappers must include `hookData` that ABI-decodes to:

```solidity
struct AuthBridgeData {
    address user;
    address executor;     // 0 = any
    uint64  deadline;
    uint64  nonce;
    bytes   userSig;
    bytes   platformSig;
}
```

The oracle verifies:

- EIP-712 signature over `AuthSwap` (same digest for user + platform)
- Deadline not expired
- Executor binding (if non-zero)
- Sequential nonce per user per pool
- Platform signer allowlist
- EIP-1271 support for contract wallets

## Oracle Immutability

The oracle and its single `platformSigner` are set once per pool during `onInitialization`
and cannot be changed. Attempts to re-initialize will revert.

## Signature Generation (SDK Guide)

The oracle verifies an EIP-712 signature over the `AuthSwap` struct. The **same digest**
is signed by both the user and the platform signer.

### Typed Data

- **Domain**
  - `name`: `"AuthBridgeDopplerHook"`
  - `version`: `"1"`
  - `chainId`: current chain ID
  - `verifyingContract`: `AuthBridgeOracle` address (per pool)

- **Primary Type**: `AuthSwap`

```solidity
AuthSwap(
  address user,
  address executor,
  bytes32 poolId,
  bool    zeroForOne,
  int256  amountSpecified,
  uint160 sqrtPriceLimitX96,
  uint64  nonce,
  uint64  deadline
)
```

### Example (TypeScript + ethers v6)

```ts
import { ethers } from "ethers";

const domain = {
  name: "AuthBridgeDopplerHook",
  version: "1",
  chainId,
  verifyingContract: authBridgeOracleAddress,
};

const types = {
  AuthSwap: [
    { name: "user", type: "address" },
    { name: "executor", type: "address" },
    { name: "poolId", type: "bytes32" },
    { name: "zeroForOne", type: "bool" },
    { name: "amountSpecified", type: "int256" },
    { name: "sqrtPriceLimitX96", type: "uint160" },
    { name: "nonce", type: "uint64" },
    { name: "deadline", type: "uint64" },
  ],
};

const value = {
  user,
  executor,        // 0x000...000 to allow any executor
  poolId,          // bytes32
  zeroForOne,
  amountSpecified, // int256
  sqrtPriceLimitX96,
  nonce,
  deadline,        // unix seconds
};

const userSig = await userWallet.signTypedData(domain, types, value);
const platformSig = await platformWallet.signTypedData(domain, types, value);

// Hook data
const hookData = ethers.AbiCoder.defaultAbiCoder().encode(
  [
    "tuple(address user,address executor,uint64 deadline,uint64 nonce,bytes userSig,bytes platformSig)"
  ],
  [{ user, executor, deadline, nonce, userSig, platformSig }]
);
```

### Notes

- `nonce` is sequential per `(poolId, user)` and is stored in the oracle.
- `deadline` is enforced by the oracle. Use short TTLs.
- `executor` binding is optional; set to zero address to allow any sender.
