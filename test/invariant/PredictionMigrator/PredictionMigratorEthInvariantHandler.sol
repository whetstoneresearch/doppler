// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import {
    InvariantPredictionERC20,
    PredictionMigratorAirlockHarness,
    PredictionMigratorInvariantHandlerBase
} from "test/invariant/PredictionMigrator/PredictionMigratorInvariantHandler.sol";

/// @dev Handler exposing bounded actions for ETH-numeraire PredictionMigrator invariants.
contract PredictionMigratorEthInvariantHandler is PredictionMigratorInvariantHandlerBase {
    constructor(
        PredictionMigratorAirlockHarness airlock_,
        PredictionMigrator migrator_,
        InvariantPredictionERC20 tokenA_,
        InvariantPredictionERC20 tokenB_,
        address oracleA_,
        address oracleB_,
        bytes32 entryIdA_,
        bytes32 entryIdB_,
        address alice_,
        address bob_
    )
        PredictionMigratorInvariantHandlerBase(
            airlock_, migrator_, tokenA_, tokenB_, oracleA_, oracleB_, entryIdA_, entryIdB_, alice_, bob_
        )
    { }

    receive() external payable { }

    // =========================================================================
    // Migration Actions
    // =========================================================================

    function migrateOracleA(uint128 amountSeed, uint8 orderingSeed) external override {
        _migrate(oracleA, entryIdA, tokenA, amountSeed, orderingSeed);
    }

    function migrateOracleB(uint128 amountSeed, uint8 orderingSeed) external override {
        _migrate(oracleB, entryIdB, tokenB, amountSeed, orderingSeed);
    }

    function _migrate(
        address oracle,
        bytes32 entryId,
        InvariantPredictionERC20 asset,
        uint128 amountSeed,
        uint8 orderingSeed
    ) internal {
        if (_entryAlreadyMigrated(oracle, entryId)) return;

        uint256 amount = _boundMigrationAmount(amountSeed);
        payable(address(migrator)).transfer(amount);

        if (orderingSeed % 2 == 0) {
            airlock.migrate(address(asset), address(0));
        } else {
            airlock.migrate(address(0), address(asset));
        }

        _recordMigration(oracle, entryId, amount);
    }
}
