/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { IHookFactory } from "src/interfaces/IHookFactory.sol";
import { Doppler } from "src/Doppler.sol";

error NotAirlock();

contract DopplerFactory is IHookFactory {
    address public immutable airlock;

    constructor(
        address airlock_
    ) {
        airlock = airlock_;
    }

    function create(
        IPoolManager poolManager,
        uint256 numTokensToSell,
        bytes memory data,
        bytes32 salt
    ) external returns (address) {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        (
            uint256 minimumProceeds,
            uint256 maximumProceeds,
            uint256 startingTime,
            uint256 endingTime,
            int24 startingTick,
            int24 endingTick,
            uint256 epochLength,
            int24 gamma,
            bool isToken0,
            uint256 numPDSlugs,
            address airlock
        ) = abi.decode(data, (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, address));

        return address(
            new Doppler{ salt: salt }(
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
                numPDSlugs,
                airlock
            )
        );
    }
}
