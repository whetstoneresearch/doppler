// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";

/// @dev Minimal ERC20 used by prediction migrator invariant tests.
contract InvariantPredictionERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Minimal harness that acts as Airlock for PredictionMigrator invariant tests.
contract PredictionMigratorAirlockHarness {
    PredictionMigrator public migrator;
    bool public isConfigured;

    function setMigrator(PredictionMigrator migrator_) external {
        require(!isConfigured, "already configured");
        migrator = migrator_;
        isConfigured = true;
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address) {
        return migrator.initialize(asset, numeraire, data);
    }

    function migrate(address token0, address token1) external returns (uint256) {
        return migrator.migrate(0, token0, token1, address(0));
    }
}

/// @dev Shared base for PredictionMigrator invariant handlers across numeraire variants.
abstract contract PredictionMigratorInvariantHandlerBase is Test {
    uint256 public constant ENTRY_SUPPLY = 1_000_000 ether;
    uint256 public constant MAX_MIGRATION_AMOUNT = 250_000 ether;

    PredictionMigratorAirlockHarness public airlock;
    PredictionMigrator public migrator;
    InvariantPredictionERC20 public tokenA;
    InvariantPredictionERC20 public tokenB;
    address public oracleA;
    address public oracleB;
    bytes32 public entryIdA;
    bytes32 public entryIdB;
    address public alice;
    address public bob;

    uint256 public ghost_totalContributed;
    uint256 public ghost_totalClaimed;
    mapping(address oracle => uint256 totalPot) public ghost_marketPot;
    mapping(address oracle => uint256 totalClaimed) public ghost_marketClaimed;
    mapping(address oracle => mapping(bytes32 entryId => bool migrated)) public ghost_entryMigrated;
    mapping(address oracle => mapping(bytes32 entryId => uint256 contribution)) public ghost_entryContribution;

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
    ) {
        airlock = airlock_;
        migrator = migrator_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        oracleA = oracleA_;
        oracleB = oracleB_;
        entryIdA = entryIdA_;
        entryIdB = entryIdB_;
        alice = alice_;
        bob = bob_;
    }

    // =========================================================================
    // Migration Actions (variant-specific implementations)
    // =========================================================================

    function migrateOracleA(uint128 amountSeed, uint8 orderingSeed) external virtual;

    function migrateOracleB(uint128 amountSeed, uint8 orderingSeed) external virtual;

    // =========================================================================
    // Claim Actions
    // =========================================================================

    function claimOracleA(uint128 amountSeed, uint8 actorSeed) external {
        _claim(oracleA, entryIdA, tokenA, amountSeed, actorSeed);
    }

    function claimOracleB(uint128 amountSeed, uint8 actorSeed) external {
        _claim(oracleB, entryIdB, tokenB, amountSeed, actorSeed);
    }

    function _claim(
        address oracle,
        bytes32 entryId,
        InvariantPredictionERC20 winningToken,
        uint128 amountSeed,
        uint8 actorSeed
    ) internal {
        if (!ghost_entryMigrated[oracle][entryId]) return;

        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 actorBalance = winningToken.balanceOf(actor);
        if (actorBalance == 0) return;

        uint256 claimTokenAmount = bound(uint256(amountSeed), 1, actorBalance);
        uint256 expectedPayout = migrator.previewClaim(oracle, claimTokenAmount);
        if (expectedPayout == 0) return;

        vm.startPrank(actor);
        winningToken.approve(address(migrator), claimTokenAmount);
        migrator.claim(oracle, claimTokenAmount);
        vm.stopPrank();

        ghost_marketClaimed[oracle] += expectedPayout;
        ghost_totalClaimed += expectedPayout;
    }

    // =========================================================================
    // Token Transfer Actions
    // =========================================================================

    function transferOracleATokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(tokenA, amountSeed, fromSeed);
    }

    function transferOracleBTokens(uint128 amountSeed, uint8 fromSeed) external {
        _transferBetweenClaimants(tokenB, amountSeed, fromSeed);
    }

    function _transferBetweenClaimants(InvariantPredictionERC20 token, uint128 amountSeed, uint8 fromSeed) internal {
        address from = fromSeed % 2 == 0 ? alice : bob;
        address to = from == alice ? bob : alice;

        uint256 fromBalance = token.balanceOf(from);
        if (fromBalance == 0) return;

        uint256 amount = bound(uint256(amountSeed), 1, fromBalance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    // =========================================================================
    // Shared Migration Helpers
    // =========================================================================

    function _recordMigration(address oracle, bytes32 entryId, uint256 amount) internal {
        ghost_entryMigrated[oracle][entryId] = true;
        ghost_entryContribution[oracle][entryId] = amount;
        ghost_marketPot[oracle] += amount;
        ghost_totalContributed += amount;
    }

    function _entryAlreadyMigrated(address oracle, bytes32 entryId) internal view returns (bool) {
        return ghost_entryMigrated[oracle][entryId];
    }

    function _boundMigrationAmount(uint128 amountSeed) internal pure returns (uint256) {
        return bound(uint256(amountSeed), 1, MAX_MIGRATION_AMOUNT);
    }
}

/// @dev ERC20-numeraire implementation of PredictionMigrator invariant handler.
contract PredictionMigratorInvariantHandler is PredictionMigratorInvariantHandlerBase {
    InvariantPredictionERC20 public numeraire;

    constructor(
        PredictionMigratorAirlockHarness airlock_,
        PredictionMigrator migrator_,
        InvariantPredictionERC20 numeraire_,
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
    {
        numeraire = numeraire_;
    }

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
        numeraire.transfer(address(migrator), amount);

        if (orderingSeed % 2 == 0) {
            airlock.migrate(address(asset), address(numeraire));
        } else {
            airlock.migrate(address(numeraire), address(asset));
        }

        _recordMigration(oracle, entryId, amount);
    }
}
