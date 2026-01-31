// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";


error SenderNotExecutor();
error SenderNotAuthorized();
error PoolNotRegistered();
error PoolRegistrationMismatch();
error InsufficientInventory();
error InvalidDeposit();

/**
 * @title TwapVault
 * @notice Middleware vault sitting between token supply (manual deposits + pull adapters)
 *         and the TWAP swap executor.
 *
 * Design goals:
 * - Hold custody of both asset inventory and numeraire proceeds.
 * - Support "releaseable" tokens AND normal ERC20 / native ETH.
 * - Maintain accurate per-pool accounting via `inventory[poolId][token]`.
 * - No permissionless pull entrypoint; inventory must be deposited explicitly.
 *
 * Notes:
 * - Proceeds remain vaulted. buybackDst may withdraw later.
 * - TWAP execution is swap-driven via the Doppler hook; the vault never triggers swaps.
 */
contract TwapVault is Ownable {
    using SafeTransferLib for address;

    /// @notice TWAP executor (hook) that is allowed to debit/credit during unlockCallback.
    address public executor;

    struct PoolInfo {
        address asset;
        address numeraire;
        address buybackDst;
    }

    /// @notice Per-pool static info.
    mapping(PoolId poolId => PoolInfo info) public poolInfo;

    /// @notice Resolves poolId by asset address (since Doppler pools are identified by asset).
    mapping(address asset => PoolId poolId) public poolIdOfAsset;

    /// @notice Per-pool inventory accounting (token -> amount reserved for that pool).
    mapping(PoolId poolId => mapping(address token => uint256 amount)) public inventory;

    event ExecutorSet(address indexed executor);
    event PoolRegistered(PoolId indexed poolId, address indexed asset, address indexed numeraire, address buybackDst);

    event InventoryDeposited(PoolId indexed poolId, address indexed token, address indexed from, uint256 amount);
    event InventoryWithdrawn(PoolId indexed poolId, address indexed token, address indexed to, uint256 amount);

    receive() external payable { }

    constructor(address owner_) Ownable(owner_) { }

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert SenderNotExecutor();
        _;
    }

    function _requireRegistered(PoolId poolId) internal view {
        if (poolInfo[poolId].asset == address(0)) revert PoolNotRegistered();
    }

    function _onlyBuybackDst(PoolId poolId) internal view {
        if (msg.sender != poolInfo[poolId].buybackDst) revert SenderNotAuthorized();
    }

    // ---------------------------------------------------------------------
    // Pool registration (called by the executor hook during onInitialization)
    // ---------------------------------------------------------------------

    function registerPool(PoolId poolId, address asset, address numeraire, address buybackDst) external onlyExecutor {
        PoolInfo storage info = poolInfo[poolId];

        // First registration.
        if (info.asset == address(0)) {
            info.asset = asset;
            info.numeraire = numeraire;
            info.buybackDst = buybackDst;
            poolIdOfAsset[asset] = poolId;
            emit PoolRegistered(poolId, asset, numeraire, buybackDst);
            return;
        }

        // Idempotent registration (exact match).
        if (info.asset != asset || info.numeraire != numeraire || info.buybackDst != buybackDst) {
            revert PoolRegistrationMismatch();
        }
    }

    // ---------------------------------------------------------------------
    // Deposits / withdrawals (authority only; inventory must always be accurate)
    // ---------------------------------------------------------------------

    function deposit(PoolId poolId, address token, uint256 amount) external payable {
        _deposit(poolId, token, amount);
    }

    /// @notice Convenience overload keyed by `asset`.
    function deposit(address asset, address token, uint256 amount) external payable {
        PoolId poolId = poolIdOfAsset[asset];
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotRegistered();
        _deposit(poolId, token, amount);
    }

    function _deposit(PoolId poolId, address token, uint256 amount) internal {
        _requireRegistered(poolId);
        _onlyBuybackDst(poolId);
        if (amount == 0) return;

        if (token == address(0)) {
            // Native ETH deposit.
            if (msg.value != amount) revert InvalidDeposit();
        } else {
            if (msg.value != 0) revert InvalidDeposit();
            token.safeTransferFrom(msg.sender, address(this), amount);
        }

        inventory[poolId][token] += amount;
        emit InventoryDeposited(poolId, token, msg.sender, amount);
    }

    function withdraw(PoolId poolId, address token, uint256 amount, address to) external {
        _withdraw(poolId, token, amount, to);
    }

    /// @notice Convenience overload keyed by `asset`.
    function withdraw(address asset, address token, uint256 amount, address to) external {
        PoolId poolId = poolIdOfAsset[asset];
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotRegistered();
        _withdraw(poolId, token, amount, to);
    }

    function _withdraw(PoolId poolId, address token, uint256 amount, address to) internal {
        _requireRegistered(poolId);
        _onlyBuybackDst(poolId);
        if (amount == 0) return;

        uint256 inv = inventory[poolId][token];
        if (inv < amount) revert InsufficientInventory();
        inventory[poolId][token] = inv - amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            token.safeTransfer(to, amount);
        }

        emit InventoryWithdrawn(poolId, token, to, amount);
    }

    // ---------------------------------------------------------------------
    // Executor-only accounting hooks (called inside PoolManager.unlockCallback)
    // ---------------------------------------------------------------------

    function debitToExecutor(PoolId poolId, address token, uint256 amount, address to) external onlyExecutor {
        if (amount == 0) return;

        uint256 inv = inventory[poolId][token];
        if (inv < amount) revert InsufficientInventory();
        inventory[poolId][token] = inv - amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            token.safeTransfer(to, amount);
        }
    }

    function creditFromExecutor(PoolId poolId, address token, uint256 amount) external onlyExecutor {
        if (amount == 0) return;
        inventory[poolId][token] += amount;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return SafeTransferLib.balanceOf(token, address(this));
    }
}
