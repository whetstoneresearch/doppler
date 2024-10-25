/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHookFactory} from "src/interfaces/IHookFactory.sol";
import {Doppler} from "src/Doppler.sol";
import {HookMiner} from "src/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DopplerFactory is IHookFactory {
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
        bytes memory,
        bytes32 salt
    ) external returns (address) {
        return address(
            new Doppler{salt: salt}(
                poolManager,
                numTokensToSell,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0
            )
        );
    }

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
    ) public view returns (address hookAddress, bytes32 salt) {
        (hookAddress, salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            type(Doppler).creationCode,
            abi.encode(
                poolManager,
                numTokensToSell,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0
            )
        );
    }
}