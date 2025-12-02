// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/PoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { Test } from "forge-std/Test.sol";
import {
    Doppler,
    InvalidEpochLength,
    InvalidGamma,
    InvalidNumPDSlugs,
    InvalidProceedLimits,
    InvalidStartTime,
    InvalidTickRange,
    InvalidTimeRange,
    MAX_PRICE_DISCOVERY_SLUGS
} from "src/initializers/Doppler.sol";
import { HookConfig, HookConfigs } from "test/shared/HookConfigs.sol";

contract DopplerNoValidateHook is Doppler {
    constructor(
        HookConfig memory config,
        address poolManager,
        address initializer,
        bytes32 salt
    )
        Doppler(
            IPoolManager(poolManager),
            config.numTokensToSell,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            config.startingTick,
            config.endingTick,
            config.epochLength,
            config.gamma,
            config.isToken0,
            config.numPDSlugs,
            initializer,
            config.initialLpFee
        )
    { }

    function validateHookAddress(BaseHook _this) internal pure override { }
}

/// @dev Just a small contract to deploy Doppler contracts and be able to use `vm.expectRevert` easily
contract Deployer {
    function deploy(
        HookConfig memory config,
        address poolManager,
        address initializer,
        bytes32 salt
    ) external returns (DopplerNoValidateHook) {
        DopplerNoValidateHook doppler = new DopplerNoValidateHook{ salt: salt }(config, poolManager, initializer, salt);
        return doppler;
    }
}

contract ConstructorTest is Test {
    Deployer deployer;
    address manager = address(0x1234);
    address initializer = address(0x5678);
    bytes32 salt = salt;

    function setUp() public {
        deployer = new Deployer();
    }

    function test_constructor_RevertsWhenStartingTimeLowerThanBlockTimestamp() public {
        vm.warp(1);
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.startingTime = 0;
        vm.expectRevert(InvalidStartTime.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidTimeRange_WhenStartingTimeEqualToEndingTime() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.startingTime = config.endingTime;
        vm.expectRevert(InvalidTimeRange.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidTimeRange_WhenStartingTimeGreaterThanToEndingTime() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.startingTime = config.endingTime + 1;
        vm.expectRevert(InvalidTimeRange.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidTickRange_WhenIsToken0_AndStartingTickLowerThanEndingTick() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        (config.startingTick, config.endingTick) = (config.endingTick, config.startingTick);
        vm.expectRevert(InvalidTickRange.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidTickRange_WhenIsToken1_AndStartingTickGreaterThanEndingTick() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_1();
        (config.startingTick, config.endingTick) = (config.endingTick, config.startingTick);
        vm.expectRevert(InvalidTickRange.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaZero() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_1();
        config.gamma = 0;
        vm.expectRevert(InvalidGamma.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaIsNegative() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_1();
        config.gamma = -1;
        vm.expectRevert(InvalidGamma.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidGamma_WhenInvalidUpperSlugCalculation() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.gamma = 3;
        vm.expectRevert(InvalidGamma.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidEpochLength_WhenTimeDeltaNotDivisibleByEpochLength() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.epochLength = 3000;
        vm.expectRevert(InvalidEpochLength.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidNumPDSlugs_WithZeroSlugs() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.numPDSlugs = 0;
        vm.expectRevert(InvalidNumPDSlugs.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidNumPDSlugs_GreaterThanMax() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        config.numPDSlugs = MAX_PRICE_DISCOVERY_SLUGS + 1;
        vm.expectRevert(InvalidNumPDSlugs.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_RevertsInvalidProceedLimits_WhenMinimumProceedsGreaterThanMaximumProceeds() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        (config.minimumProceeds, config.maximumProceeds) = (config.maximumProceeds, config.minimumProceeds);
        vm.expectRevert(InvalidProceedLimits.selector);
        deployer.deploy(config, manager, initializer, salt);
    }

    function test_constructor_Succeeds_WithValidParameters() public {
        HookConfig memory config = HookConfigs.DEFAULT_CONFIG_0();
        DopplerNoValidateHook doppler = deployer.deploy(config, manager, initializer, salt);

        assertEq(doppler.numTokensToSell(), config.numTokensToSell);
        assertEq(doppler.minimumProceeds(), config.minimumProceeds);
        assertEq(doppler.maximumProceeds(), config.maximumProceeds);
        assertEq(doppler.startingTime(), config.startingTime);
        assertEq(doppler.endingTime(), config.endingTime);
        assertEq(doppler.startingTick(), config.startingTick);
        assertEq(doppler.endingTick(), config.endingTick);
        assertEq(doppler.epochLength(), config.epochLength);
        assertEq(doppler.gamma(), config.gamma);
        assertEq(doppler.isToken0(), config.isToken0);
        assertEq(doppler.numPDSlugs(), config.numPDSlugs);
        assertEq(doppler.initialLpFee(), config.initialLpFee);
    }
}
