// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { PoolId } from "@v4-core/types/PoolId.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";

import { FeesManager } from "src/base/FeesManager.sol";

contract FeesManagerImplementation is FeesManager {
    function _collectFees(
        PoolId poolId
    ) internal pure override returns (BalanceDelta fees) {
        return BalanceDelta.wrap(0);
    }
}

contract FeesManagerTest is Test { }
