/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to move liquidity from Uniswap v4 to v2
 */
interface IMigrator {
    // TODO: Maybe make this function payable so we can send ETH along?
    function migrate(address router) external returns (address pool);
}
