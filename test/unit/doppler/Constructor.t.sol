// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { BaseTest, TestERC20 } from "test/shared/BaseTest.sol";
import { DopplerImplementation } from "test/shared/DopplerImplementation.sol";
import {
    Doppler,
    MAX_TICK_SPACING,
    MAX_PRICE_DISCOVERY_SLUGS,
    InvalidTickRange,
    InvalidGamma,
    InvalidEpochLength,
    InvalidTimeRange,
    InvalidTickSpacing,
    InvalidNumPDSlugs,
    InvalidProceedLimits,
    InvalidStartTime
} from "src/Doppler.sol";

using PoolIdLibrary for PoolKey;

contract DopplerNoValidateHook is Doppler {
    constructor(
        IPoolManager poolManager_,
        uint256 numTokensToSell_,
        uint256 minimumProceeds_,
        uint256 maximumProceeds_,
        uint256 startingTime_,
        uint256 endingTime_,
        int24 startingTick_,
        int24 endingTick_,
        uint256 epochLength_,
        int24 gamma_,
        bool isToken0_,
        uint256 numPDSlugs_,
        address initializer_,
        uint24 initialLpFee_
    )
        Doppler(
            poolManager_,
            numTokensToSell_,
            minimumProceeds_,
            maximumProceeds_,
            startingTime_,
            endingTime_,
            startingTick_,
            endingTick_,
            epochLength_,
            gamma_,
            isToken0_,
            numPDSlugs_,
            initializer_,
            initialLpFee_
        )
    { }

    function validateHookAddress(
        BaseHook _this
    ) internal pure override { }
}

contract Deployer {
    // TODO: Use a struct to clean this up
    function deploy(
        address poolManager,
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
        uint256 numPDSlugs,
        address airlock,
        uint24 lpFee,
        bytes32 salt
    ) external returns (DopplerNoValidateHook) {
        DopplerNoValidateHook doppler = new DopplerNoValidateHook{ salt: salt }(
            IPoolManager(poolManager),
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
            airlock,
            lpFee
        );

        return doppler;
    }
}

contract ConstructorTest is BaseTest {
    Deployer deployer;

    function setUp() public override {
        deployer = new Deployer();
    }

    function test_constructor_RevertsWhenStartingTimeLowerThanBlockTimestamp() public {
        vm.warp(1);
        vm.expectRevert(InvalidStartTime.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            0,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidTickRange_WhenIsToken0_AndStartingTickLEEndingTick() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        vm.expectRevert(InvalidTickRange.selector);
        deployer.deploy(
            address(manager),
            config.numTokensToSell,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            100,
            101,
            config.epochLength,
            config.gamma,
            true,
            config.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidTickRange_WhenNotIsToken0_AndStartingTickGEEndingTick() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        vm.expectRevert(InvalidTickRange.selector);
        deployer.deploy(
            address(manager),
            config.numTokensToSell,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            200,
            100,
            config.epochLength,
            config.gamma,
            false,
            config.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidGamma_tickDeltaNotDivisibleByEpochsTimesGamma() public {
        vm.skip(true);
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.gamma = 5;
        config.startingTime = 1000;
        config.endingTime = 5000;
        config.epochLength = 1000;

        vm.expectRevert(InvalidTickRange.selector);
        deployer.deploy(
            address(manager),
            config.numTokensToSell,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            config.epochLength,
            config.gamma,
            false,
            config.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidTickSpacing_WhenTickSpacingGreaterThanMax() public {
        vm.skip(true);
        int24 maxTickSpacing = MAX_TICK_SPACING;
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.tickSpacing = int24(maxTickSpacing + 1);

        // deployDoppler(InvalidTickSpacing.selector, config, 0, 0, true);

        DopplerNoValidateHook doppler = deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidTimeRange_WhenStartingTimeGreaterThanOrEqualToEndingTime() public {
        vm.expectRevert(InvalidTimeRange.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            1000,
            1000,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaCalculationZero() public {
        vm.skip(true);
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.startingTime = 1000;
        config.endingTime = 1001;
        config.epochLength = 1;
        config.gamma = 0;

        // deployDoppler(InvalidGamma.selector, config, 0, 0, true);
    }

    function test_constructor_RevertsInvalidEpochLength_WhenTimeDeltaNotDivisibleByEpochLength() public {
        vm.expectRevert(InvalidEpochLength.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            3000,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaNotDivisibleByTickSpacing() public {
        vm.expectRevert(InvalidGamma.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma + 1,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaTimesTotalEpochsNotDivisibleByTotalTickDelta() public {
        vm.skip(true);
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.gamma = 10;
        config.startingTime = 1000;
        config.endingTime = 5000;
        config.epochLength = 1000;

        // deployDoppler(InvalidGamma.selector, config, 0, 0, true);
    }

    function test_constructor_RevertsInvalidGamma_WhenGammaIsNegative() public {
        vm.expectRevert(InvalidGamma.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            int24(-1),
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidNumPDSlugs_WithZeroSlugs() public {
        vm.skip(true);
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.numPDSlugs = 0;

        // deployDoppler(InvalidNumPDSlugs.selector, config, 0, 0, true);
    }

    function test_constructor_RevertsInvalidNumPDSlugs_GreaterThanMax() public {
        vm.expectRevert(InvalidNumPDSlugs.selector);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            MAX_PRICE_DISCOVERY_SLUGS + 1,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_RevertsInvalidProceedLimits_WhenMinimumProceedsGreaterThanMaximumProceeds() public {
        vm.skip(true);
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.minimumProceeds = 100;
        config.maximumProceeds = 0;

        // deployDoppler(InvalidProceedLimits.selector, config, 0, 0, true);
        deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );
    }

    function test_constructor_Succeeds_WithValidParameters() public {
        DopplerNoValidateHook doppler = deployer.deploy(
            address(manager),
            DEFAULT_DOPPLER_CONFIG.numTokensToSell,
            DEFAULT_DOPPLER_CONFIG.minimumProceeds,
            DEFAULT_DOPPLER_CONFIG.maximumProceeds,
            DEFAULT_DOPPLER_CONFIG.startingTime,
            DEFAULT_DOPPLER_CONFIG.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_DOPPLER_CONFIG.epochLength,
            DEFAULT_DOPPLER_CONFIG.gamma,
            isToken0,
            DEFAULT_DOPPLER_CONFIG.numPDSlugs,
            address(0xbeef),
            3000,
            bytes32(0)
        );

        assertEq(doppler.numTokensToSell(), DEFAULT_DOPPLER_CONFIG.numTokensToSell);
        assertEq(doppler.minimumProceeds(), DEFAULT_DOPPLER_CONFIG.minimumProceeds);
        assertEq(doppler.maximumProceeds(), DEFAULT_DOPPLER_CONFIG.maximumProceeds);
        assertEq(doppler.startingTime(), DEFAULT_DOPPLER_CONFIG.startingTime);
        assertEq(doppler.endingTime(), DEFAULT_DOPPLER_CONFIG.endingTime);
        assertEq(doppler.startingTick(), DEFAULT_START_TICK);
        assertEq(doppler.endingTick(), DEFAULT_END_TICK);
        assertEq(doppler.epochLength(), DEFAULT_DOPPLER_CONFIG.epochLength);
        assertEq(doppler.gamma(), DEFAULT_DOPPLER_CONFIG.gamma);
        assertEq(doppler.isToken0(), isToken0);
        assertEq(doppler.numPDSlugs(), DEFAULT_DOPPLER_CONFIG.numPDSlugs);
        assertEq(doppler.initialLpFee(), 3000);
    }
}
