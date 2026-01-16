// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

// ============ Errors ============

/// @notice Thrown when payout address is zero
error InvalidPayout();

/// @notice Thrown when underlying migrator address is zero or self
error InvalidUnderlying();

/// @notice Thrown when percentWad exceeds MAX_DISTRIBUTION_WAD
error InvalidPercent();

/// @notice Thrown when config already exists for token pair
error AlreadyInitialized();

/// @notice Thrown when config does not exist for token pair
error PoolNotInitialized();

/// @notice Thrown when provided token pair doesn't match stored (asset, numeraire)
error TokenPairMismatch();

/// @notice Thrown when underlying migrator is not whitelisted by Airlock
error UnderlyingNotWhitelisted();

/// @notice Thrown when underlying migrator's airlock is not this contract
error UnderlyingNotForwarded();

/// @notice Thrown when underlying V4 migrator is not approved in locker (optional preflight)
error UnderlyingNotLockerApproved();

/// @notice Thrown when hook's migrator doesn't match underlying (optional preflight)
error UnderlyingHookMismatch();

// ============ Events ============

/**
 * @notice Emitted when distribution is paid to payout address
 * @param payout Address receiving the distribution
 * @param numeraire Token being distributed (address(0) for ETH)
 * @param amount Amount distributed
 * @param percentWad Distribution percentage in WAD
 */
event Distribution(address indexed payout, address indexed numeraire, uint256 amount, uint256 percentWad);

/**
 * @notice Emitted when migration is forwarded to underlying migrator
 * @param underlying Address of the underlying migrator
 * @param token0 First token of the pair
 * @param token1 Second token of the pair
 * @param sqrtPriceX96 Square root price for migration
 */
event WrappedMigration(
    address indexed underlying, address indexed token0, address indexed token1, uint160 sqrtPriceX96
);

// ============ Interfaces ============

/// @notice Interface to check if a contract has an airlock() accessor
interface IHasAirlock {
    function airlock() external view returns (Airlock);
}

/// @notice Interface for V4 migrator preflight checks
interface IV4MigratorPreflight {
    function locker() external view returns (address);
    function migratorHook() external view returns (address);
}

/// @notice Interface for StreamableFeesLocker approval check
interface ILockerApproval {
    function approvedMigrators(address) external view returns (bool);
}

/// @notice Interface for hook migrator binding check
interface IHookMigrator {
    function migrator() external view returns (address);
}

// ============ Storage ============

/**
 * @notice Configuration for distribution per token pair
 * @param payout Address receiving the distribution
 * @param percentWad Distribution percentage in WAD (1e18 = 100%)
 * @param underlying The underlying migrator to forward to
 * @param asset The asset token address
 * @param numeraire The numeraire token address (address(0) for ETH)
 */
struct DistributionConfig {
    address payout;
    uint256 percentWad;
    ILiquidityMigrator underlying;
    address asset;
    address numeraire;
}

// ============ Constants ============

/// @dev 1e18 - used for percentage calculations
uint256 constant WAD = 1e18;

/// @dev Maximum distribution percentage (50%)
uint256 constant MAX_DISTRIBUTION_WAD = 5e17;

/**
 * @title DistributionMigrator
 * @author Whetstone Research
 * @notice Wrapper migrator that distributes a share of numeraire proceeds before forwarding to underlying migrator
 * @custom:security-contact security@whetstone.cc
 */
contract DistributionMigrator is ILiquidityMigrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @notice Configuration for each token pair
    mapping(address token0 => mapping(address token1 => DistributionConfig)) public getDistributionConfig;

    /**
     * @notice Constructor
     * @param airlock_ Address of the real Airlock contract
     */
    constructor(address airlock_) ImmutableAirlock(airlock_) { }

    /**
     * @notice Returns the owner of the real Airlock
     * @dev Required for forwarded V4 migrators that call airlock.owner()
     */
    function owner() external view returns (address) {
        return airlock.owner();
    }

    /**
     * @notice Receives ETH from Airlock
     * @dev Restricted to Airlock only
     */
    receive() external payable onlyAirlock { }

    /**
     * @notice Initializes distribution config and forwards to underlying migrator
     * @param asset The asset token address
     * @param numeraire The numeraire token address (address(0) for ETH)
     * @param data Encoded (payout, percentWad, underlyingMigrator, underlyingData)
     * @return migrationPool The migration pool address from the underlying migrator
     */
    function initialize(
        address asset,
        address numeraire,
        bytes calldata data
    ) external onlyAirlock returns (address migrationPool) {
        // Decode payload
        (address payout, uint256 percentWad, address underlyingMigrator, bytes memory underlyingData) =
            abi.decode(data, (address, uint256, address, bytes));

        // Basic validation
        if (payout == address(0)) revert InvalidPayout();
        if (underlyingMigrator == address(0) || underlyingMigrator == address(this)) revert InvalidUnderlying();
        if (percentWad > MAX_DISTRIBUTION_WAD) revert InvalidPercent();

        // Compute sorted token pair
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        // Check for overwrites
        if (getDistributionConfig[token0][token1].payout != address(0)) revert AlreadyInitialized();

        // Verify underlying is whitelisted by Airlock
        if (airlock.getModuleState(underlyingMigrator) != ModuleState.LiquidityMigrator) {
            revert UnderlyingNotWhitelisted();
        }

        // Verify underlying is forwarded to this contract (its airlock == address(this))
        if (address(IHasAirlock(underlyingMigrator).airlock()) != address(this)) {
            revert UnderlyingNotForwarded();
        }

        // Optional V4 preflight checks (fail-fast for V4 migrators)
        // These are SHOULD checks per spec - helps catch misconfiguration early
        _performV4PreflightChecks(underlyingMigrator);

        // Store config with BOTH asset and numeraire explicitly (underlyingData is NOT stored per spec)
        // Storing both enables explicit validation in migrate() - prevents ordering spoofing
        getDistributionConfig[token0][token1] = DistributionConfig({
            payout: payout,
            percentWad: percentWad,
            underlying: ILiquidityMigrator(underlyingMigrator),
            asset: asset,
            numeraire: numeraire
        });

        // Forward initialize to underlying migrator
        migrationPool = ILiquidityMigrator(underlyingMigrator).initialize(asset, numeraire, underlyingData);
    }

    /**
     * @notice Distributes numeraire proceeds and forwards remaining balances to underlying migrator
     * @param sqrtPriceX96 Square root price for migration
     * @param token0 First token of the pair (sorted)
     * @param token1 Second token of the pair (sorted)
     * @param recipient Recipient of the liquidity position
     * @return liquidity Amount of liquidity created by underlying migrator
     */
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256 liquidity) {
        // Look up config using sorted key
        DistributionConfig memory config = getDistributionConfig[token0][token1];
        if (config.payout == address(0)) revert PoolNotInitialized();

        // Verify token pair matches stored config EXACTLY (order-independent)
        // This prevents ordering spoofing if poolInitializer returns unexpected tokens
        bool validPair = (config.asset == token0 && config.numeraire == token1)
            || (config.asset == token1 && config.numeraire == token0);
        if (!validPair) revert TokenPairMismatch();

        // Use stored numeraire directly (no derivation needed - more secure)
        address numeraire = config.numeraire;

        // CEI Pattern: Delete config BEFORE external calls to prevent reentrancy
        // We've already loaded config into memory, so this is safe
        delete getDistributionConfig[token0][token1];

        // Compute numeraire balance and distribution
        uint256 numeraireBalance;
        if (numeraire == address(0)) {
            numeraireBalance = address(this).balance;
        } else {
            numeraireBalance = ERC20(numeraire).balanceOf(address(this));
        }

        uint256 distribution = (numeraireBalance * config.percentWad) / WAD;

        // Pay distribution to payout address
        if (distribution > 0) {
            if (numeraire == address(0)) {
                SafeTransferLib.safeTransferETH(config.payout, distribution);
            } else {
                ERC20(numeraire).safeTransfer(config.payout, distribution);
            }
            emit Distribution(config.payout, numeraire, distribution, config.percentWad);
        }

        // Forward remaining balances to underlying migrator
        address underlying = address(config.underlying);

        // Transfer token0 balance (if not ETH)
        if (token0 != address(0)) {
            uint256 balance0 = ERC20(token0).balanceOf(address(this));
            if (balance0 > 0) {
                ERC20(token0).safeTransfer(underlying, balance0);
            }
        }

        // Transfer token1 balance
        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        if (balance1 > 0) {
            ERC20(token1).safeTransfer(underlying, balance1);
        }

        // Forward ETH if token0 is ETH
        uint256 ethToForward = token0 == address(0) ? address(this).balance : 0;

        emit WrappedMigration(underlying, token0, token1, sqrtPriceX96);

        // Call underlying migrate
        liquidity = config.underlying.migrate{ value: ethToForward }(sqrtPriceX96, token0, token1, recipient);
    }

    // ============ Internal Functions ============

    /**
     * @notice Performs optional V4 preflight checks for fail-fast validation
     * @dev These are SHOULD checks per spec - helps catch misconfiguration at create-time rather than migrate-time
     * @param underlyingMigrator Address of the underlying migrator to check
     */
    function _performV4PreflightChecks(address underlyingMigrator) internal view {
        // Try to get locker and check approval (V4 migrators only)
        try IV4MigratorPreflight(underlyingMigrator).locker() returns (address locker) {
            if (locker != address(0)) {
                try ILockerApproval(locker).approvedMigrators(underlyingMigrator) returns (bool approved) {
                    if (!approved) revert UnderlyingNotLockerApproved();
                } catch {
                    // Locker doesn't have approvedMigrators - skip check
                }
            }
        } catch {
            // Not a V4 migrator or doesn't have locker() - skip check
        }

        // Try to get hook and check migrator binding (V4 migrators only)
        try IV4MigratorPreflight(underlyingMigrator).migratorHook() returns (address hook) {
            if (hook != address(0)) {
                try IHookMigrator(hook).migrator() returns (address hookMigrator) {
                    if (hookMigrator != underlyingMigrator) revert UnderlyingHookMismatch();
                } catch {
                    // Hook doesn't have migrator() - skip check
                }
            }
        } catch {
            // Not a V4 migrator or doesn't have migratorHook() - skip check
        }
    }
}
