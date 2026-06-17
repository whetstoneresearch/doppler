// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Stores amount values for each currency referenced by a pool key
 * @dev Used by migrators to inform lockers of the amounts of each currency to lock
 * @param value0 Amount of currency0
 * @param value1 Amount of currency1
 */
struct Values {
    uint256 value0;
    uint256 value1;
}
