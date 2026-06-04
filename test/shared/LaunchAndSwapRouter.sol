// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IERC20Minimal } from "@v4-core/interfaces/external/IERC20Minimal.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock, CreateParams } from "src/Airlock.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

contract LaunchAndSwapRouter {
    Airlock public immutable airlock;
    DopplerHookInitializer public immutable initializer;
    PoolSwapTest public immutable swapRouter;

    constructor(Airlock airlock_, DopplerHookInitializer initializer_, PoolSwapTest swapRouter_) {
        airlock = airlock_;
        initializer = initializer_;
        swapRouter = swapRouter_;
    }

    function launchAndSwap(
        CreateParams memory createParams,
        IPoolManager.SwapParams memory swapParams,
        address inputToken
    ) external payable returns (address asset) {
        (asset,,,,) = airlock.create(createParams);
        (,,,,, PoolKey memory key,) = initializer.getState(asset);
        IERC20Minimal(inputToken).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(key, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }
}
