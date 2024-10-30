/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IHookFactory} from "src/interfaces/IHookFactory.sol";
import {Doppler} from "src/Doppler.sol";

contract DopplerFactory is IHookFactory {
    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        bool isToken0,
        int24 startingTick,
        int24 endingTick,
        bytes memory data,
        bytes32 salt
    ) external returns (address) {
        (
            uint256 minimumProceeds,
            uint256 maximumProceeds,
            uint256 startingTime,
            uint256 endingTime,
            uint256 epochLength,
            int24 gamma,
            uint256 numPDSlugs
        ) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256, int24, uint256));

        return address(
            new Doppler{salt: salt}(
                poolManager,
                numTokensToSell,
                minimumProceeds,
                maximumProceeds,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0,
                numPDSlugs
            )
        );
    }
}
