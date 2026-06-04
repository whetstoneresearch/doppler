// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IERC20Minimal } from "@v4-core/interfaces/external/IERC20Minimal.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

contract BundlerSwapRouter {
    DopplerHookInitializer public immutable initializer;
    PoolSwapTest public immutable swapRouter;

    constructor(DopplerHookInitializer initializer_, PoolSwapTest swapRouter_) {
        initializer = initializer_;
        swapRouter = swapRouter_;
    }

    function execute(bytes calldata, bytes[] calldata inputs) external payable {
        require(inputs.length == 1, "invalid inputs");

        (address asset, IPoolManager.SwapParams memory swapParams, address inputToken) =
            abi.decode(inputs[0], (address, IPoolManager.SwapParams, address));
        (,,,,, PoolKey memory key,) = initializer.getState(asset);

        IERC20Minimal(inputToken).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(key, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }
}
