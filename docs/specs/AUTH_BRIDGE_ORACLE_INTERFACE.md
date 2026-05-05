# Auth-Bridge Oracle Interface

The Auth Bridge oracle verifies user and auth-signer signatures, checks
executor/deadline constraints, consumes unordered nonces, and lets a disable
authority permanently turn authorization off for a lane.

## Structs

```solidity
struct AuthBridgeInitData {
    address authSigner;
    address disableAuthority;
}

struct AuthSwap {
    address user;
    address executor;
    address asset;
    bytes32 poolId;
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
    bytes32 nonce;
    uint64 deadline;
}

struct AuthTransfer {
    address token;
    address from;
    address to;
    uint256 amount;
    address executor;
    bytes32 nonce;
    uint64 deadline;
}
```

## Interface

```solidity
interface IAuthBridgeOracle {
    function initializeSwapAuthorization(
        PoolId poolId,
        address authSigner,
        address disableAuthority
    ) external;

    function initializeTransferAuthorization(
        address token,
        address authSigner,
        address disableAuthority
    ) external;

    function setTrustedCaller(address caller, bool trusted) external;

    function authorizeSwap(
        AuthSwap calldata swapAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external;

    function authorizeTransfer(
        AuthTransfer calldata transferAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external;

    function disableSwapAuthorization(PoolId poolId) external;
    function disableTransferAuthorization(address token) external;

    function isSwapAuthorizationDisabled(PoolId poolId) external view returns (bool);
    function isTransferAuthorizationDisabled(address token) external view returns (bool);
}
```

## Semantics

- Swap lanes are initialized by trusted callers during hook initialization.
- Transfer lanes are initialized by the oracle owner/admin.
- Swap and transfer lane initialization share the same explicit signer/disable-authority parameters.
- `authorizeSwap` and `authorizeTransfer` revert on failure.
- Nonces are unordered `bytes32` values keyed by `(lane, user, nonce)`.
- `executor` must match the sender provided by the trusted caller.
- The disable authority can permanently disable its lane.
- Disabled swap lanes allow the Doppler hook to skip hook data and signature checks.
- Disabled transfer lanes make `AuthBridgeTransferExecutor` revert instead of skipping auth.
