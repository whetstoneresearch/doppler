/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to migrate current liquidity to a new pool
 */
interface ILiquidityMigrator {
    function initialize(
        bytes memory data
    ) external returns (address pool);

    function migrate(
        address token0,
        address token1,
        uint256 price,
        address recipient,
        bytes memory data
    ) external payable;
}
