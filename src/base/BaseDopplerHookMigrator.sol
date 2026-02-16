// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IDopplerHookMigrator } from "src/interfaces/IDopplerHookMigrator.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";

/// @dev Flag for the `onInitialization` callback
uint256 constant ON_INITIALIZATION_FLAG = 1 << 0;

/// @dev Flag for the `onSwap` callback
uint256 constant ON_SWAP_FLAG = 1 << 1;

/// @dev Flag indicating the hook requires a dynamic LP fee pool
uint256 constant REQUIRES_DYNAMIC_LP_FEE_FLAG = 1 << 2;

/// @notice Thrown when the `msg.sender` is not the DopplerHookMigrator contract
error SenderNotMigrator();

/**
 * @title Doppler Hook Migrator Base Contract
 * @author Whetstone Research
 * @dev Base contract for the Doppler Migrator Hook contracts, here is implemented access control for the different
 * callback functions along with virtual internal functions to be overridden by child contracts
 * @custom:security-contact security@whetstone.cc
 */
abstract contract BaseDopplerHookMigrator is IDopplerHookMigrator {
    /// @notice Address of the DopplerHookMigrator contract
    DopplerHookMigrator public immutable MIGRATOR;

    /// @notice Restricts the caller to the DopplerHookMigrator contract
    modifier onlyMigrator() {
        require(msg.sender == address(MIGRATOR), SenderNotMigrator());
        _;
    }

    /**
     * @param migrator Address of the DopplerHookMigrator contract
     */
    constructor(DopplerHookMigrator migrator) {
        MIGRATOR = migrator;
    }

    /// @inheritdoc IDopplerHookMigrator
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external onlyMigrator {
        _onInitialization(asset, key, data);
    }

    /// @inheritdoc IDopplerHookMigrator
    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) external onlyMigrator returns (Currency, int128) {
        return _onSwap(sender, key, params, balanceDelta, data);
    }

    /// @dev Internal function to be overridden for initialization logic
    function _onInitialization(address asset, PoolKey calldata key, bytes calldata data) internal virtual { }

    /// @dev Internal function to be overridden for swap logic
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) internal virtual returns (Currency, int128) { }
}
