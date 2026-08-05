# Auth-Bridge Integration Guide

Auth Bridge gates Doppler hook swaps and provides an optional authorized token
transfer route. This is a hard-break interface: the existing
`AuthBridgeOracle`, `AuthBridgeDopplerHook`, and `IAuthBridgeOracle` names are
kept, but the old swap-only `isAuthorized` surface is replaced.

Auth Bridge is not an identity registry. It only checks signatures for a
specific action, executor, nonce, and deadline. Each lane also has a
`disableAuthority` that can permanently turn the auth check off.

## Contracts

- Hook: `AuthBridgeDopplerHook`
- Oracle: `AuthBridgeOracle`
- Transfer route: `AuthBridgeTransferExecutor`
- Interface: `IAuthBridgeOracle`

Source layout:

- `src/dopplerHooks/AuthBridgeDopplerHook.sol`
- `src/implementations/authBridge/AuthBridgeOracle.sol`
- `src/implementations/authBridge/AuthBridgeTransferExecutor.sol`

## Deployment

```solidity
AuthBridgeOracle oracle = new AuthBridgeOracle(owner);
AuthBridgeDopplerHook hook = new AuthBridgeDopplerHook(address(initializer), address(oracle));
AuthBridgeTransferExecutor transferExecutor = new AuthBridgeTransferExecutor(address(oracle));

vm.prank(owner);
oracle.setTrustedCaller(address(hook), true);

vm.prank(owner);
oracle.setTrustedCaller(address(transferExecutor), true);
```

Enable the hook on `DopplerHookInitializer`:

```solidity
initializer.setDopplerHookState(
    [address(hook)],
    [ON_INITIALIZATION_FLAG | ON_SWAP_FLAG]
);
```

## Pool Initialization

Pool initialization data no longer carries an oracle address. The hook uses the
oracle configured in its constructor.

```solidity
AuthBridgeInitData memory authInit = AuthBridgeInitData({
    authSigner: authSigner,
    disableAuthority: disableAuthority
});

InitData memory initData = InitData({
    // ...other fields...
    dopplerHook: address(hook),
    onInitializationDopplerHookCalldata: abi.encode(authInit),
    graduationDopplerHookCalldata: new bytes(0)
});
```

The hook initializes a swap lane keyed by `poolId`.

## Swap Authorization

Swappers include `hookData` that ABI-decodes to:

```solidity
struct AuthBridgeData {
    address user;
    address executor;
    bytes32 nonce;
    uint64 deadline;
    bytes userSig;
    bytes authSig;
}
```

The hook reconstructs and authorizes:

```solidity
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
```

EIP-712 domain:

```ts
const domain = {
  name: "AuthBridge",
  version: "1",
  chainId,
  verifyingContract: authBridgeOracleAddress,
};
```

Auth Bridge uses unordered `bytes32` nonces per `(lane, user, nonce)`, so SDKs
can prepare multiple swaps concurrently.

## Transfer Authorization

The transfer executor authorizes this typed data:

```solidity
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

Initialize a token transfer lane before using the route:

```solidity
vm.prank(owner);
oracle.initializeTransferAuthorization(token, authSigner, disableAuthority);
```

Then users grant allowance to `AuthBridgeTransferExecutor` and callers submit
`transferWithAuthorization(authTransfer, userSig, authSig)`.

The executor never bypasses token transfer hooks. For `DopplerERC20V1`, pool-lock
and balance-limit checks still run during `transferFrom`.

## Permanent Disable

Each lane has a `disableAuthority`.

- `disableSwapAuthorization(poolId)` permanently turns off swap auth for that pool lane.
- `disableTransferAuthorization(token)` permanently disables the transfer route for that token lane.

Disabled transfer lanes make `AuthBridgeTransferExecutor` revert instead of
pulling tokens without auth. Direct ERC20/Permit2 routes remain available.
