// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestERC20 } from "v4-core/src/test/TestERC20.sol";
import { PoolIdLibrary } from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { Currency } from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import { V4Quoter } from "v4-periphery/src/lens/V4Quoter.sol";
import { CustomRouter } from "test/shared/CustomRouter.sol";
import { DopplerImplementation } from "test/shared/DopplerImplementation.sol";
import { MaximumProceedsReached } from "src/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

using PoolIdLibrary for PoolKey;

contract EarlyExitTest is BaseTest {
    function deployDoppler(
        DopplerConfig memory config
    ) internal {
        (token0, token1) = isToken0 ? (asset, numeraire) : (numeraire, asset);
        TestERC20(isToken0 ? token0 : token1).transfer(address(hook), config.numTokensToSell);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        int24 _startTick = isToken0 ? DEFAULT_START_TICK : -DEFAULT_START_TICK;
        int24 _endTick = isToken0 ? -DEFAULT_END_TICK : DEFAULT_END_TICK;

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
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
        manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));

        // Deploy swapRouter
        swapRouter = new PoolSwapTest(manager);

        // Deploy modifyLiquidityRouter
        // Note: Only used to validate that liquidity can't be manually modified
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        if (token0 != address(0)) {
            // Approve the router to spend tokens on behalf of the test contract
            TestERC20(token0).approve(address(swapRouter), type(uint256).max);
            TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        quoter = new V4Quoter(manager);

        router = new CustomRouter(swapRouter, quoter, key, isToken0, usingEth);
    }

    function test_swap_RevertsIfMaximumProceedsReached() public {
        vm.skip(true);
        // DopplerConfig memory config = DEFAULT_DOPPLER_CONFIG;
        // config.maximumProceeds = 500e18;
        // _deployDoppler(config);

        vm.warp(hook.getStartingTime());

        int256 maximumProceeds = int256(hook.getMaximumProceeds());

        buy(-maximumProceeds);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch
        sellExpectRevert(-1 ether, MaximumProceedsReached.selector, true);
    }
}
