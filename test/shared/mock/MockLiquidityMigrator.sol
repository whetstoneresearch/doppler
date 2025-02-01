// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

/// @notice A mock migration contract that does absolutely nothing
/// @dev NOT TO BE USED IN PRODUCTION. TOKENS SENT HERE ARE IRRECOVERABLE
contract MockLiquidityMigrator is ILiquidityMigrator {
    event MockMigratorInitialize(address asset, address numeraire, bytes data);
    event MockMigratorMigrate(uint160 sqrtPriceX96, address token0, address token1, address recipient);

    receive() external payable { }

    function initialize(address asset, address numeraire, bytes calldata data) external override returns (address) {
        emit MockMigratorInitialize(asset, numeraire, data);
        return address(0xbeef);
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable override returns (uint256) {
        emit MockMigratorMigrate(sqrtPriceX96, token0, token1, recipient);
        return uint256(0xbeef);
    }
}
