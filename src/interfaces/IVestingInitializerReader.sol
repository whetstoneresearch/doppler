// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @notice Unified reader interface for vesting middleware to query initializer lifecycle state.
 */
interface IVestingInitializerReader {
    /**
     * @notice Returns initializer status and issuance pool key for `asset`.
     * @param asset Address of the launch asset tracked in the initializer.
     * @return status Raw initializer status enum value.
     * @return poolKey Issuance pool key for the asset.
     */
    function getVestingInitializerState(address asset) external view returns (uint8 status, PoolKey memory poolKey);
}
