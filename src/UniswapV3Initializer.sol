/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";

contract UniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback {
    address public immutable airlock;
    IUniswapV3Factory public immutable factory;

    constructor(address airlock_, IUniswapV3Factory factory_) {
        airlock = airlock_;
        factory = factory_;
    }

    function initialize(uint256 numTokensToSell, bytes32 salt, bytes memory data) external returns (address) { }

    function exitLiquidity() external { }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override { }
}
