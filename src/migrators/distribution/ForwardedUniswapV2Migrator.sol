// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IUniswapV2Factory, IUniswapV2Router02, UniswapV2Migrator } from "src/migrators/UniswapV2Migrator.sol";

/**
 * @title ForwardedUniswapV2Migrator
 * @author Whetstone Research
 * @notice UniswapV2Migrator variant whose airlock is set to a DistributionMigrator
 * @dev This contract is identical to UniswapV2Migrator except it expects its airlock
 *      to be a DistributionMigrator rather than the real Airlock. This allows the
 *      DistributionMigrator to call initialize() and migrate() which are protected
 *      by onlyAirlock.
 * @custom:security-contact security@whetstone.cc
 */
contract ForwardedUniswapV2Migrator is UniswapV2Migrator {
    /**
     * @notice Constructor
     * @param distributor_ Address of the DistributionMigrator (acts as airlock for this contract)
     * @param factory_ Address of the Uniswap V2 factory
     * @param router_ Address of the Uniswap V2 router
     * @param owner_ Address of the owner for the locker contract
     */
    constructor(
        address distributor_,
        IUniswapV2Factory factory_,
        IUniswapV2Router02 router_,
        address owner_
    ) UniswapV2Migrator(distributor_, factory_, router_, owner_) { }
}
