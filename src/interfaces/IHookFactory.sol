// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

interface IHookFactory {
    /**
     * @notice Deploys a new hook contract
     * @param poolManager Address of the Uniswap V4 pool manager
     * @param numTokensToSell Amount of asset tokens to sell
     * @param data Arbitrary data to pass
     * @param salt Salt for the create2 deployment
     */
    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        bytes memory data,
        bytes32 salt
    ) external returns (address);
}

interface IHook {
    /**
     * @notice Triggers the migration stage of the hook contract
     * @return Price of the pool
     */
    function migrate(
        address recipient
    ) external returns (uint256);
}
