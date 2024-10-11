pragma solidity 0.8.26;

import {BaseTest} from "test/shared/BaseTest.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {MAX_TICK_SPACING, InvalidTickRange, InvalidGamma, InvalidEpochLength, InvalidTimeRange, InvalidTickSpacing} from "src/Doppler.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

using PoolIdLibrary for PoolKey;

contract ConstructorTest is BaseTest {
    function setUp() public override {
        manager = new PoolManager();
        _deployTokens();
    }

    function deployDoppler(
        bytes4 selector,
        DopplerConfig memory config,
        int24 _startTick,
        int24 _endTick,
        bool _isToken0
    ) internal {
        isToken0 = _isToken0;

        (token0, token1) = isToken0 ? (asset, numeraire) : (numeraire, asset);
        (isToken0 ? token0 : token1).transfer(address(hook), config.numTokensToSell);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });
        
        if (selector != 0) {
            vm.expectRevert(selector);
        }
        deployCodeTo(
            "DopplerImplementation.sol:DopplerImplementation",
            abi.encode(
                manager,
                key,
                config.numTokensToSell,
                config.startingTime,
                config.endingTime,
                _startTick,
                _endTick,
                config.epochLength,
                config.gamma,
                isToken0,
                hook
            ),
            address(hook)
        );
        if (selector == 0) {
            poolId = key.toId();

            manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick), new bytes(0));
        }
    }

    function testConstructor_RevertsInvalidTickRange_WhenIsToken0_AndStartingTickLEEndingTick() public {
        bool _isToken0 = true;
        int24 _startTick = 100;
        int24 _endTick = 101; 

        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;

        deployDoppler(InvalidTickRange.selector, config, _startTick, _endTick, _isToken0);
    }

    function testConstructor_RevertsInvalidTickRange_WhenNotIsToken0_AndStartingTickGEEndingTick() public {
        bool _isToken0 = false;
        int24 _startTick = 200;
        int24 _endTick = 100; 

        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;

        deployDoppler(InvalidTickRange.selector, config, _startTick, _endTick, _isToken0);
    }

    function testConstructor_RevertsInvalidGamma_tickDeltaNotDivisibleByEpochsTimesGamma() public {
        bool _isToken0 = true;
        int24 _startTick = 200;
        int24 _endTick = 100;
        int24 _gamma = 5;
        uint256 _startingTime = 1000;
        uint256 _endingTime = 5000;
        uint256 _epochLength = 1000;

        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.gamma = _gamma;
        config.startingTime = _startingTime;
        config.endingTime = _endingTime;
        config.epochLength = _epochLength;

        deployDoppler(InvalidGamma.selector, config, _startTick, _endTick, _isToken0);
    }

    function testConstructor_RevertsInvalidTickSpacing_WhenTickSpacingGreaterThanMax() public {
        int24 maxTickSpacing = MAX_TICK_SPACING;
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.tickSpacing = int24(maxTickSpacing + 1);

        deployDoppler(InvalidTickSpacing.selector, config, 200, 100, true);
    }

    function testConstructor_RevertsInvalidTimeRange_WhenStartingTimeGreaterThanOrEqualToEndingTime() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.startingTime = 1000;
        config.endingTime = 1000;

        deployDoppler(InvalidTimeRange.selector, config, 200, 100, true);
    }

    function testConstructor_RevertsInvalidGamma_WhenGammaCalculationZero() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.startingTime = 1000;
        config.endingTime = 1001;
        config.epochLength = 1;
        config.gamma = 0;

        deployDoppler(InvalidGamma.selector, config, 200, 100, true);
    }

    function testConstructor_RevertsInvalidEpochLength_WhenTimeDeltaNotDivisibleByEpochLength() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.startingTime = 1000;
        config.endingTime = 5000;
        config.epochLength = 3000;

        deployDoppler(InvalidEpochLength.selector, config, 200, 100, true);
    }

    function testConstructor_RevertsInvalidGamma_WhenGammaNotDivisibleByTickSpacing() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.gamma += 1;

        deployDoppler(InvalidGamma.selector, config, 200, 100, true);
    }

    function testConstructor_Succeeds_WithValidParameters() public {
        bool _isToken0 = true;
        int24 _startTick = 0;
        int24 _endTick = -172_800;

        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;

        deployDoppler(0, config, _startTick, _endTick, _isToken0);
    }
}
