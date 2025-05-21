// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

interface ICustomLPUniswapV2Migrator is ILiquidityMigrator {
    /// @notice Thrown when the custom LP allocation exceeds `MAX_CUSTOM_LP_WAD`
    error MaxCustomLPWadExceeded();
    /// @notice Thrown when the recipient is not an EOA
    error RecipientNotEOA();
    /// @notice Thrown when the lock up period is less than `MIN_LOCK_PERIOD`
    error LessThanMinLockPeriod();
    /// @notice Thrown when the input is zero
    error InvalidInput();
}
