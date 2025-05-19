// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICustomLPUniswapV2Locker {
    /**
     * @notice State of a pool
     * @param amount0 Reserve of token0
     * @param amount1 Reserve of token1
     * @param minUnlockDate Minimum unlock date
     * @param recipient Address of the recipient
     */
    struct PoolState {
        uint112 amount0;
        uint112 amount1;
        uint32 minUnlockDate;
        address recipient;
    }

    /// @notice Thrown when the sender is not the migrator contract
    error SenderNotMigrator();

    /// @notice Thrown when trying to initialized a pool that was already initialized
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to exit a pool that was not initialized
    error PoolNotInitialized();

    /// @notice Thrown when the Locker contract doesn't hold any LP tokens
    error NoBalanceToLock();

    /// @notice Thrown when the minimum unlock date has not been reached
    error MinUnlockDateNotReached();

    function receiveAndLock(address pool, address recipient, uint32 lockPeriod) external;

    function claimFeesAndExit(
        address pool
    ) external;
}
