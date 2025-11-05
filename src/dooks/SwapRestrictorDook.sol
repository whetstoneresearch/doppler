// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BaseDook } from "src/base/BaseDook.sol";

error SenderNotApprovedToSwap();

contract SwapRestrictorDook is BaseDook {
    mapping(PoolId poolId => mapping(address sender => bool isApproved)) public isApproved;

    constructor(address initializer, address hook) BaseDook(initializer, hook) { }

    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override {
        require(isApproved[key.toId()][sender], SenderNotApprovedToSwap());
    }
}
