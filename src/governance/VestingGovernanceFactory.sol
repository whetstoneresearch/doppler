// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { InitializerKind, VestingMiddleware } from "src/governance/VestingMiddleware.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

/// @notice Thrown when beneficiary is zero address
error InvalidBeneficiary();

/// @notice Thrown when factory grace duration is below 5 minutes
error InvalidFactoryGraceDuration(uint32 graceDuration);

/**
 * @notice Vesting governance configuration passed through `governanceFactoryData`.
 * @param launchpadAdmin Owner/admin address for the deployed middleware (`address(0)` disables admin commands)
 * @param beneficiary Fixed p0 beneficiary for numeraire pulls and transfer instructions
 * @param governanceExecutor Optional secondary executor during grace windows (ignored when `launchpadAdmin` is zero)
 * @param streamStart Timestamp for period 0 unlock (defaults to block.timestamp when zero)
 * @param periodDuration Seconds per vesting period (minimum 15 minutes enforced by middleware)
 * @param numeraire Expected numeraire address for this launch
 * @param initializerKind Reader kind for initializer state (`0` = multicurve-like, `1` = doppler hook)
 */
struct VestingGovernanceData {
    address launchpadAdmin;
    address beneficiary;
    address governanceExecutor;
    uint64 streamStart;
    uint32 periodDuration;
    address numeraire;
    uint8 initializerKind;
}

/// @notice Emitted when a middleware timelock is deployed for an asset.
event CreateVestingMiddleware(
    address indexed asset,
    address indexed middleware,
    address indexed launchpadAdmin,
    address beneficiary,
    address governanceExecutor,
    address numeraire,
    InitializerKind initializerKind,
    uint64 streamStart,
    uint32 periodDuration,
    uint32 graceDuration
);

/**
 * @title VestingGovernanceFactory
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Governance factory variant that deploys `VestingMiddleware` and returns it as timelock.
 */
contract VestingGovernanceFactory is IGovernanceFactory, ImmutableAirlock {
    uint32 public constant MIN_GRACE_DURATION = 5 minutes;

    IPoolManager public immutable poolManager;
    uint32 public immutable graceDuration;

    constructor(address airlock_, IPoolManager poolManager_, uint32 graceDuration_) ImmutableAirlock(airlock_) {
        if (graceDuration_ < MIN_GRACE_DURATION) revert InvalidFactoryGraceDuration(graceDuration_);
        poolManager = poolManager_;
        graceDuration = graceDuration_;
    }

    /// @inheritdoc IGovernanceFactory
    function create(address asset, bytes calldata governanceData) external onlyAirlock returns (address, address) {
        VestingGovernanceData memory config = abi.decode(governanceData, (VestingGovernanceData));
        if (config.beneficiary == address(0)) revert InvalidBeneficiary();

        uint64 streamStart = config.streamStart == 0 ? uint64(block.timestamp) : config.streamStart;
        bool noAdminMode = config.launchpadAdmin == address(0);
        address owner = noAdminMode ? address(this) : config.launchpadAdmin;

        VestingMiddleware middleware = new VestingMiddleware(
            address(airlock),
            asset,
            config.numeraire,
            poolManager,
            config.beneficiary,
            config.governanceExecutor,
            streamStart,
            config.periodDuration,
            graceDuration,
            config.initializerKind,
            owner
        );

        address resolvedExecutor = config.governanceExecutor == address(0) ? config.launchpadAdmin : config.governanceExecutor;
        if (noAdminMode) {
            resolvedExecutor = address(middleware);
            middleware.setGovernanceExecutor(resolvedExecutor);
            middleware.transferOwnership(address(middleware));
        }

        emit CreateVestingMiddleware(
            asset,
            address(middleware),
            config.launchpadAdmin,
            config.beneficiary,
            resolvedExecutor,
            config.numeraire,
            InitializerKind(config.initializerKind),
            streamStart,
            config.periodDuration,
            graceDuration
        );

        return (DEAD_ADDRESS, address(middleware));
    }
}
