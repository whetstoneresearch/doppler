// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV4Migrator } from "src/migrators/UniswapV4Migrator.sol";

/**
 * @title ForwardedUniswapV4Migrator
 * @author Whetstone Research
 * @notice UniswapV4Migrator variant whose airlock is set to a DistributionMigrator
 * @dev This contract is identical to UniswapV4Migrator except it expects its airlock
 *      to be a DistributionMigrator rather than the real Airlock. This allows the
 *      DistributionMigrator to call initialize() and migrate() which are protected
 *      by onlyAirlock.
 *
 *      IMPORTANT: The migratorHook passed to this contract MUST be deployed with
 *      this ForwardedUniswapV4Migrator as its migrator address. And the locker
 *      MUST have this ForwardedUniswapV4Migrator approved via approveMigrator().
 *
 * @custom:security-contact security@whetstone.cc
 */
contract ForwardedUniswapV4Migrator is UniswapV4Migrator {
    /**
     * @notice Constructor
     * @param distributor_ Address of the DistributionMigrator (acts as airlock for this contract)
     * @param poolManager_ Address of the Uniswap V4 Pool Manager contract
     * @param positionManager_ Address of the Uniswap V4 Position Manager contract
     * @param locker_ Address of the Streamable Fees Locker contract
     * @param migratorHook_ Address of the Uniswap V4 Migrator Hook contract
     */
    constructor(
        address distributor_,
        IPoolManager poolManager_,
        PositionManager positionManager_,
        StreamableFeesLocker locker_,
        IHooks migratorHook_
    ) UniswapV4Migrator(distributor_, poolManager_, positionManager_, locker_, migratorHook_) { }
}
