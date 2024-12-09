// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IPoolInitializer {
    /**
     * @notice Creates a new pool to bootstrap liquidity
     * @param numTokensToSell Amount of asset tokens to sell
     * @param salt Salt for the create2 deployment
     * @param data Arbitrary data to pass
     * @param pool Address of the pool
     */
    function initialize(
        address asset,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes memory data
    ) external returns (address pool);

    function exitLiquidity(
        address asset
    ) external returns (address token0, address token1, uint256 price);
}

interface IHook {
    /**
     * @notice Triggers the migration stage of the hook contract
     * @return Price of the pool
     */
    function migrate(
        address recipient
    ) external returns (uint256);
}