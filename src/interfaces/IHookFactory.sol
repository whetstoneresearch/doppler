// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IHookFactory {
    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        bytes memory,
        bytes32 salt
    ) external returns (address);

    function predict(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        bytes memory
    ) external view returns (address hookAddress, bytes32 salt);
}
