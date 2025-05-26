// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";

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

contract TestHookConfigs is Test {
    function test_computeGamma() public view {
        console.log("gamma", HookConfigs.computeGamma(200 seconds, 28_800 hours, 8));
    }
}

library HookConfigs {
    function computeGamma(uint256 epochLength, uint256 timeDelta, int24 tickSpacing) internal pure returns (int24) {
        int24 minGamma = int24(int256((timeDelta + epochLength - 1) / epochLength)); // ceil division
        int24 validGamma = ((minGamma + tickSpacing - 1) / tickSpacing) * tickSpacing;
        return validGamma;
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
