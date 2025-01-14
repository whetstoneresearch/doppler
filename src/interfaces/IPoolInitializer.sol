// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Contracts inheriting from this interface are in charge of creating new
 * liquidity pools and migrating liquidity under specific conditions
 */
interface IPoolInitializer {
    /**
     * @notice Creates a new pool to bootstrap liquidity
     * @param numTokensToSell Amount of asset tokens to sell
     * @param salt Salt for the create2 deployment
     * @param data Arbitrary data to pass
     * @param pool Address of the freshly deployed pool or the hook
     */
    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes calldata data
    ) external returns (address pool);

    /**
     * @notice Removes liquidity from a pool
     * @param target Address to target for the migration (pool or hook)
     * @return sqrtPriceX96 Square root of the price of the pool in the Q96 format
     * @return token0 Address of the token0
     * @return fees0 Amount of fees accrued for token0
     * @return balance0 Amount of token0 in the pool
     * @return token1 Address of the token1
     * @return fees1 Amount of fees accrued for token1
     * @return balance1 Amount of token1 in the pool
     */
    function exitLiquidity(
        address target
    )
        external
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        );
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
