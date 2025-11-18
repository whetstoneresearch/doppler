// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { BaseDook } from "src/base/BaseDook.sol";

/**
 * @notice Thrown when a swap is attempted before the sale has started
 * @param startingTime Timestamp when the sale is scheduled to start
 * @param actualTime Current block timestamp
 */
error SaleHasNotStartedYet(uint256 startingTime, uint256 actualTime);

/**
 * @title Scheduled Launch Dook
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Doppler Hook allowing to schedule a launch time for a pool
 */
contract ScheduledLaunchDook is BaseDook {
    /// @notice Returns the scheduled starting time associated with a Uniswap V4 poolId
    mapping(PoolId poolId => uint256 startingTime) public getStartingTimeOf;

    /// @param initializer Address of the Dook Multicurve Initializer contract
    constructor(address initializer) BaseDook(initializer) { }

    /// @inheritdoc BaseDook
    function _onInitialization(address, PoolKey calldata key, bytes calldata data) internal override {
        uint256 startingTime = abi.decode(data, (uint256));
        PoolId poolId = key.toId();
        getStartingTimeOf[poolId] = startingTime;
    }

    /// @inheritdoc BaseDook
    function _onSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal view override {
        PoolId poolId = key.toId();
        uint256 startingTime = getStartingTimeOf[poolId];
        require(block.timestamp >= startingTime, SaleHasNotStartedYet(startingTime, block.timestamp));
    }
}
