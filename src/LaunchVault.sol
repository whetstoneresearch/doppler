// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solady/utils/ReentrancyGuard.sol";
import {Airlock} from "src/Airlock.sol";
import {DERC20} from "src/tokens/DERC20.sol";

/// @notice Simplified LaunchVault - just custody and release
/// @dev Vesting/Merkle/Splits handled by external contracts
contract LaunchVault is ReentrancyGuard {
    /// @notice Airlock contract for migration checks
    Airlock public immutable airlock;

    /// @notice Total prebuy amount per asset
    mapping(address asset => uint256 totalAmount) public prebuyTotal;

    /// @notice Distributor address for each asset (external vesting/merkle contract)
    mapping(address asset => address distributor) public distributor;

    /// @notice Trusted executor (timelock/bundler) that can deposit prebuy
    mapping(address executor => bool trusted) public trustedExecutors;

    /// @notice Custom errors
    error NotUnlocked();
    error ZeroAmount();
    error AlreadyDeposited();
    error NoDistributorSet();
    error NotTrustedExecutor();
    error WrongAmount(uint256 received, uint256 expected);
    error InsufficientBalance(uint256 balance, uint256 required);

    /// @notice Events
    event PrebuyDeposited(address indexed asset, address indexed beneficiary, uint256 amount);
    event ReleasedToDistributor(address indexed asset, address indexed distributor, uint256 amount);
    event DistributorSet(address indexed asset, address indexed distributor);
    event TrustedExecutorSet(address indexed executor, bool trusted);

    constructor(address airlock_) {
        airlock = Airlock(payable(airlock_));
    }

    /// @notice Check if asset has been migrated via Airlock
    /// @param asset The asset token address (must be DERC20)
    /// @return True if the asset's pool is unlocked (migration complete)
    function isUnlocked(address asset) public view returns (bool) {
        return DERC20(asset).isPoolUnlocked();
    }

    /// @notice Set trusted executor status
    /// @param executor The address to set trust status for
    /// @param trusted Whether the executor is trusted
    function setTrustedExecutor(address executor, bool trusted) external {
        // In production, add access control (only timelock/owner)
        trustedExecutors[executor] = trusted;
        emit TrustedExecutorSet(executor, trusted);
    }

    /// @notice Record prebuy tokens deposited to vault (push model)
    /// @dev Only trusted executors (timelock/bundler) can record deposits
    ///      Tokens must already be transferred to vault before calling this
    /// @param asset The asset token address
    /// @param beneficiary The beneficiary (for tracking, not custody)
    /// @param amount Amount that was deposited
    function depositPrebuy(address asset, address beneficiary, uint256 amount) external nonReentrant {
        _validateAndRecordDeposit(asset, beneficiary, amount);
        
        // Verify vault actually received the tokens (push model)
        uint256 balance = SafeTransferLib.balanceOf(asset, address(this));
        if (balance < amount) revert InsufficientBalance(balance, amount);
    }

    /// @notice Deposit prebuy tokens by pulling from DERC20 vesting (pull model)
    /// @dev Users vest tokens in DERC20 with vault as recipient, then this pulls via release()
    /// @param asset The asset token address (must be DERC20)
    /// @param beneficiary The beneficiary (for tracking)
    /// @param expectedAmount Expected amount to pull (for validation)
    function depositPrebuyFromRelease(address asset, address beneficiary, uint256 expectedAmount) external nonReentrant {
        _validateAndRecordDeposit(asset, beneficiary, expectedAmount);
        
        // Pull released tokens from DERC20 (pull model)
        uint256 balanceBefore = DERC20(asset).balanceOf(address(this));
        DERC20(asset).release();
        uint256 amount = DERC20(asset).balanceOf(address(this)) - balanceBefore;
        
        // Validate amount matches expectation
        if (amount != expectedAmount) revert WrongAmount(amount, expectedAmount);
    }

    /// @notice Internal function to validate and record a deposit
    /// @param asset The asset token address
    /// @param beneficiary The beneficiary (for tracking)
    /// @param amount Amount to record
    function _validateAndRecordDeposit(address asset, address beneficiary, uint256 amount) internal {
        if (!trustedExecutors[msg.sender]) revert NotTrustedExecutor();
        if (amount == 0) revert ZeroAmount();
        if (prebuyTotal[asset] > 0) revert AlreadyDeposited();

        // Track total
        prebuyTotal[asset] = amount;

        emit PrebuyDeposited(asset, beneficiary, amount);
    }

    /// @notice Set the distributor address for an asset
    /// @param asset The asset token
    /// @param distributor_ The external distributor (vesting/merkle/splits contract)
    function setDistributor(address asset, address distributor_) external {
        // In production, add access control (only timelock/owner)
        distributor[asset] = distributor_;
        emit DistributorSet(asset, distributor_);
    }

    /// @notice Release all tokens to the distributor
    /// @param asset The asset to release
    function releaseToDistributor(address asset) external nonReentrant {
        if (!isUnlocked(asset)) revert NotUnlocked();

        address dist = distributor[asset];
        if (dist == address(0)) revert NoDistributorSet();

        uint256 amount = prebuyTotal[asset];
        if (amount == 0) return; // Nothing to release

        // Clear tracking before transfer (CEI pattern)
        prebuyTotal[asset] = 0;

        // Send all tokens to distributor
        SafeTransferLib.safeTransfer(asset, dist, amount);

        emit ReleasedToDistributor(asset, dist, amount);
    }

    /// @notice Release tokens to a specific recipient (fallback for simple cases)
    /// @param asset The asset to release
    /// @param recipient Where to send the tokens
    function releaseTo(address asset, address recipient) external nonReentrant {
        if (!isUnlocked(asset)) revert NotUnlocked();
        if (recipient == address(0)) revert NoDistributorSet();

        uint256 amount = prebuyTotal[asset];
        if (amount == 0) return;

        // Clear tracking before transfer
        prebuyTotal[asset] = 0;

        // Send tokens
        SafeTransferLib.safeTransfer(asset, recipient, amount);

        emit ReleasedToDistributor(asset, recipient, amount);
    }
}
