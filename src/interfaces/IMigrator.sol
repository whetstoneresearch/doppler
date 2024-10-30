/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to migrate current liquidity to a new pool
 */
interface IMigrator {
    function migrate(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address recipient,
        bytes memory data
    ) external payable returns (address pool, uint256 liquidity);
}
