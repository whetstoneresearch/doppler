// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { isTickSpacingValid } from "src/libraries/TickLibrary.sol";
import { BeneficiaryData, validateBeneficiaries } from "src/types/BeneficiaryData.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @notice Data to use for the migration
 * @param poolKey Key of the Uniswap V4 pool to migrate liquidity to
 * @param lockDuration Duration for which the liquidity will be locked in the locker contract
 * @param beneficiaries Array of beneficiaries used by the locker contract
 */
struct AssetData {
    PoolKey poolKey;
    uint32 lockDuration;
    BeneficiaryData[] beneficiaries;
}

/// @dev Empty address used to indicate no pool address exists (because Uniswap V4 is a singleton)
address constant EMPTY_ADDRESS = address(0xdead);

contract UniswapV4MulticurveMigrator is ILiquidityMigrator, ImmutableAirlock {
    /// @notice Address of the Uniswap V4 Pool Manager contract
    IPoolManager public immutable poolManager;

    /// @notice Address of the Uniswap V4 Migrator hook
    IHooks public immutable migratorHook;

    /// @notice Mapping of asset pairs to their respective asset data
    mapping(address token0 => mapping(address token1 => AssetData data)) public getAssetData;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param migratorHook_ Address of the Migrator hook, note that a fresh deployment
     * is required to set this contract as the migrator address
     */
    constructor(address airlock_, IPoolManager poolManager_, IHooks migratorHook_) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        migratorHook = migratorHook_;
    }

    function initialize(address asset, address numeraire, bytes calldata data) external onlyAirlock returns (address) {
        (uint24 fee, int24 tickSpacing, uint32 lockDuration, BeneficiaryData[] memory beneficiaries, int24 spread) =
            abi.decode(data, (uint24, int24, uint32, BeneficiaryData[], int24));

        isTickSpacingValid(tickSpacing);
        LPFeeLibrary.validate(fee);
        validateBeneficiaries(airlock.owner(), beneficiaries);

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: migratorHook,
            fee: fee,
            tickSpacing: tickSpacing
        });

        getAssetData[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] =
            AssetData({ poolKey: poolKey, lockDuration: lockDuration, beneficiaries: beneficiaries });

        // Uniswap V4 pools are represented by their PoolKey, so we return an empty address instead
        return EMPTY_ADDRESS;
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) { }
}
