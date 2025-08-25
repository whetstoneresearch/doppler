// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";

contract UniswapV4MulticurveInitializerTest is Deployers {
    UniswapV4MulticurveInitializer public initializer;
    address public airlock = makeAddr("airlock");

    function test_setUp() public {
        deployFreshManager();
        // initializer = new UniswapV4MulticurveInitializer(airlock, manager);
    }
}
