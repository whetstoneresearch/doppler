// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { PoolId } from "@v4-core/types/PoolId.sol";

struct AuthSwap {
    address user;
    address executor;
    bytes32 poolId;
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
    uint64 nonce;
    uint64 deadline;
}

interface IAuthBridgeOracle {
    function initialize(PoolId poolId, address asset, bytes calldata data) external;

    function isAuthorized(
        AuthSwap calldata swap,
        address sender,
        bytes calldata userSig,
        bytes calldata platformSig
    ) external returns (bool);
}
