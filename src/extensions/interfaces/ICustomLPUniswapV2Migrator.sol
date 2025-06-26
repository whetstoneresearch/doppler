// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

interface ICustomLPUniswapV2Migrator is ILiquidityMigrator {
    struct CustomLPState {
        /// @dev Lock up period for the LP tokens allocated to `customLPRecipient`
        uint32 lockUpPeriod;
        /// @dev Allow custom allocation of LP tokens other than `LP_TO_LOCK_WAD` (% expressed in WAD)
        uint64 customLPWad;
        /// @dev Address of the recipient of the custom LP allocation
        address customLPRecipient;
    }

    /// @notice Thrown when the custom LP allocation exceeds `MAX_CUSTOM_LP_WAD`
    error MaxCustomLPWadExceeded();
    /// @notice Thrown when the recipient is not an EOA
    error RecipientNotEOA();
    /// @notice Thrown when the lock up period is less than `MIN_LOCK_PERIOD`
    error LessThanMinLockPeriod();
    /// @notice Thrown when the input is zero
    error InvalidInput();
}
