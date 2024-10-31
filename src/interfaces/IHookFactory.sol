// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IHookFactory {
    function create(IPoolManager poolManager, uint256 numTokensToSell, bytes memory data, bytes32 salt)
        external
        returns (address);
}

interface IHook {
    function migrate() external returns (uint256 amount0, uint256 amount1);
}
