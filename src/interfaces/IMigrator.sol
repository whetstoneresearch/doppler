/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to migrate current liquidity to a new pool
 */
interface IMigrator {
    function createPool(address token0, address token1) external returns (address);

    function migrate(
        address token0,
        address token1,
        uint256 price,
        address recipient,
        bytes calldata data
    ) external payable returns (address pool, uint256 liquidity);
}
