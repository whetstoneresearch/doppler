// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { MAX_PRICE_DISCOVERY_SLUGS, MAX_TICK_SPACING } from "src/initializers/Doppler.sol";

struct HookConfig {
    uint256 numTokensToSell;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 startingTime;
    uint256 endingTime;
    uint256 epochLength;
    int24 gamma;
    uint24 initialLpFee;
    int24 tickSpacing;
    uint256 numPDSlugs;
    int24 startingTick;
    int24 endingTick;
    bool isToken0;
}

library HookConfigs {
    function isValidConfig(HookConfig memory config) internal pure returns (bool) { }

    function generateConfig(uint256 seed) internal pure returns (HookConfig memory config) {
        bool isToken0 = seed % 2 == 0;
        int24 tickSpacing = (int24(uint24(seed)) % MAX_TICK_SPACING) + 1;
        uint256 numPDSlugs = seed % MAX_PRICE_DISCOVERY_SLUGS + 1;
        uint256 startingTime = seed % type(uint256).max / 2;
        uint256 epochLength = seed % 10 days + 1 minutes;
        uint256 totalEpochs = (seed % 200) + 1;
        uint256 endingTime = startingTime + (totalEpochs * epochLength);
        int24 gamma = 0;
        int24 startingTick = TickMath.MIN_TICK + (int24(uint24(seed)) % (TickMath.MAX_TICK - TickMath.MIN_TICK));
        int24 endingTick = startingTick + (int24(uint24(seed)) % (TickMath.MAX_TICK - startingTick));

        if (isToken0) {
            startingTick = -startingTick;
            endingTick = -endingTick;
        }

        uint256 numTokensToSell = seed % type(uint64).max + 1;
        uint256 minimumProceeds = (seed % 100 ether) + 1 ether;
        uint256 maximumProceeds = minimumProceeds + (seed % 10 ether) + 1 ether;
    }

    function DEFAULT_CONFIG_0() internal pure returns (HookConfig memory) {
        return HookConfig({
            numTokensToSell: 6e28,
            minimumProceeds: 1.5 ether,
            maximumProceeds: 12.5 ether,
            startingTime: 1 days,
            endingTime: 1 days + 6 hours,
            epochLength: 200 seconds,
            gamma: 4864,
            initialLpFee: 20_000,
            tickSpacing: 8,
            numPDSlugs: 10,
            startingTick: -172_504,
            endingTick: -260_000,
            isToken0: true
        });
    }

    function DEFAULT_CONFIG_1() internal pure returns (HookConfig memory) {
        HookConfig memory config = DEFAULT_CONFIG_0();
        config.isToken0 = false;
        config.startingTick = -config.startingTick;
        config.endingTick = -config.endingTick;
        return config;
    }
}
