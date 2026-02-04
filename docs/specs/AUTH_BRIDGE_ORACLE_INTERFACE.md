# Auth-Bridge Oracle Interface (Minimal)

This describes the on-chain interface expected by the hook.

## Structs

```solidity
struct AuthSwap {
    address user;
    address executor;
    bytes32 poolId;
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
    uint64  nonce;
    uint64  deadline;
}
```

## Interface

```solidity
interface IAuthBridgeOracle {
    function initialize(PoolId poolId, address asset, bytes calldata data) external;

    function isAuthorized(
        AuthSwap calldata swap,
        address sender,
        bytes calldata userSig,
        bytes calldata platformSig
    ) external returns (bool);
}
```

### Semantics

- `initialize` is called once per pool by the hook during `onInitialization`.
- `isAuthorized` returns `true` only if:
  - signatures are valid (user + platform)
  - nonce is expected
  - deadline is not expired
  - executor binding matches (if provided)
  - platform signer matches the single immutable signer for the pool

Oracle is responsible for all replay protection and signature verification logic.
The platform signer is configured once per pool during `initialize` and cannot be changed.
