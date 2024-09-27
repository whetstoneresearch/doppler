/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHookFactory} from "src/interfaces/IHookFactory.sol";
import {Doppler} from "src/Doppler.sol";

contract DopplerFactory is IHookFactory {
    function create(IPoolManager poolManager, bytes memory hookData) external returns (address) {
        (
            uint256 numTokensToSell,
            uint256 startingTime,
            uint256 endingTime,
            int24 startingTick,
            int24 endingTick,
            uint256 epochLength,
            uint256 gamma,
            bool isToken0
        ) = abi.decode(hookData, (uint256, uint256, uint256, int24, int24, uint256, uint256, bool));

        return address(
            new Doppler(
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
