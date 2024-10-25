/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHookFactory} from "src/interfaces/IHookFactory.sol";
import {Doppler} from "src/Doppler.sol";
import {HookMiner} from "src/HookMiner.sol";

contract DopplerFactory is IHookFactory {
    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 startingTime,
        uint256 endingTime,
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
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
                minimumProceeds,
                maximumProceeds,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0,
                3 // numPDSlugs
            )
        );
    }

    function predict(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 startingTime,
        uint256 endingTime,
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        bytes memory
    ) public view returns (address hookAddress, bytes32 salt) {
        (hookAddress, salt) = HookMiner.find(
            address(this),
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ),
            type(Doppler).creationCode,
            abi.encode(
                poolManager,
                numTokensToSell,
                startingTime,
                endingTime,
                minimumProceeds,
                maximumProceeds,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0
            )
        );
    }
}
