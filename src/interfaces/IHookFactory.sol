// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IHookFactory {
    function create(IPoolManager poolManager, bytes memory hookData) external returns (address);
}
