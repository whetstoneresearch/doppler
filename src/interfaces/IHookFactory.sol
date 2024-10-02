// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IHookFactory {
    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        uint256 gamma,
        bool isToken0,
        bytes memory hookData,
        bytes32 salt
    ) external returns (address);
    function predict(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        uint256 gamma,
        bool isToken0,
        bytes memory
    ) external view returns (address hookAddress, bytes32 salt);
}
