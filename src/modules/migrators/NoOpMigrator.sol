// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

/// @dev Thrown when attempting to migrate liquidity
error CannotMigrate();

/// @dev Burn address used as a dead address for no-op operations
address constant DEAD_ADDRESS = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

/**
 * @author Whetstone Research
 * @notice No-op migrator that does not perform any migration
 * @custom:security-contact security@whetstone.cc
 */
contract NoOpMigrator is ILiquidityMigrator, ImmutableAirlock {
    /// @param airlock_ Address of the Airlock contract
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    /// @inheritdoc ILiquidityMigrator
    function initialize(address, address, bytes calldata) external view onlyAirlock returns (address) {
        return DEAD_ADDRESS;
    }

    /// @inheritdoc ILiquidityMigrator
    function migrate(uint160, address, address, address) external payable onlyAirlock returns (uint256) {
        revert CannotMigrate();
    }
}
