// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";

contract UniswapV4MulticurveInitializerTest is Deployers {
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public hook;
    address public airlock = makeAddr("airlock");

    function test_setUp() public {
        deployFreshManager();
        hook = UniswapV4MulticurveInitializerHook(address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144)));
        initializer = new UniswapV4MulticurveInitializer(airlock, manager, hook);
    }
}
