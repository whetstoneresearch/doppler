// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

/// @notice A mock migration contract that does absolutely nothing
/// @dev NOT TO BE USED IN PRODUCTION. TOKENS SENT HERE ARE IRRECOVERABLE
contract MockLiquidityMigrator is ILiquidityMigrator {
    receive() external payable { }

    function initialize(address asset, address numeraire, bytes calldata data) external override returns (address) { }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable override returns (uint256) { }
}
