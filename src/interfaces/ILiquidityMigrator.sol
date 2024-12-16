/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to migrate current liquidity to a new pool
 */
interface ILiquidityMigrator {
    function initialize(address asset, address numeraire, bytes calldata data) external returns (address pool);

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        address recipient,
        bytes calldata data
    ) external payable returns (uint256 liquidity);
}
