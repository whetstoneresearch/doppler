// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @notice Unified reader interface for vesting middleware to query migrator lifecycle state.
 */
interface IVestingMigratorReader {
    /**
     * @notice Returns migrator status, migration pool key and fee locker for `asset`.
     * @param asset Address of the launch asset tracked in Airlock.
     * @param initializerPoolKey Cached initializer pool key for the asset.
     * @return status Raw migrator status enum value (0 means uninitialized).
     * @return poolKey Migration pool key.
     * @return locker Address of the locker collecting streamable fees.
     */
    function getVestingMigratorState(
        address asset,
        PoolKey calldata initializerPoolKey
    ) external view returns (uint8 status, PoolKey memory poolKey, address locker);
}
