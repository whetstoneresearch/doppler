pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseTest} from "test/shared/BaseTest.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MaximumProceedsReached} from "src/Doppler.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import "forge-std/console.sol";

using PoolIdLibrary for PoolKey;

contract ConstructorTest is BaseTest {
    function setUp() public override {
        manager = new PoolManager();
        _deployTokens();
    }

    function deployDoppler(
        DopplerConfig memory config
    ) internal {
        (token0, token1) = isToken0 ? (asset, numeraire) : (numeraire, asset);
        (isToken0 ? token0 : token1).transfer(address(hook), config.numTokensToSell);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        int24 _startTick = isToken0 ? DEFAULT_START_TICK : -DEFAULT_START_TICK;
        int24 _endTick = isToken0 ? -DEFAULT_END_TICK : DEFAULT_END_TICK;

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });
        deployCodeTo(
            "DopplerImplementation.sol:DopplerImplementation",
            abi.encode(
                manager,
                key,
                config.numTokensToSell,
                config.minimumProceeds,
                config.maximumProceeds,
                config.startingTime,
                config.endingTime,
                _startTick,
                _endTick,
                config.epochLength,
                config.gamma,
                isToken0,
                config.numPDSlugs,
                hook
            ),
            address(hook)
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick), new bytes(0));

        // Deploy swapRouter
        swapRouter = new PoolSwapTest(manager);

        // Deploy modifyLiquidityRouter
        // Note: Only used to validate that liquidity can't be manually modified
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Approve the router to spend tokens on behalf of the test contract
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_swap_RevertsIfMaximumProceedsReached() public {
        DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        config.maximumProceeds = 500e18;

        deployDoppler(config);

        vm.warp(hook.getStartingTime());

        int256 maximumProceeds = int256(hook.getMaximumProceeds());

        swapRouter.swap(
            key,
            IPoolManager.SwapParams(!isToken0, -maximumProceeds, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(MaximumProceedsReached.selector)
            )
        );
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(isToken0, -1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }
}