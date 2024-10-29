/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @notice Generic interface to migrate current liquidity to a new pool
 */
interface IMigrator {
    function migrate(address asset, address numeraire, uint256 amountAsset, uint256 amountNumeraire, bytes memory data)
        external
        payable
        returns (address pool);
}
