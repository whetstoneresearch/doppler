// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";

/// @dev Flag for the `onInitialization` callback
uint256 constant ON_INITIALIZATION_FLAG = 1 << 0;

/// @dev Flag for the `onSwap` callback
uint256 constant ON_SWAP_FLAG = 1 << 1;

/// @dev Flag for the `onGraduation` callback
uint256 constant ON_GRADUATION_FLAG = 1 << 2;

/// @notice Thrown when the `msg.sender` is not the DopplerHookInitializer contract
error SenderNotInitializer();

/**
 * @title Doppler Hook Base Contract
 * @author Whetstone Research
 * @dev Base contract for the Doppler Hooks, here is implemented access control for the different
 * callback functions along with virtual internal functions to be overridden by child contracts
 * @custom:security-contact security@whetstone.cc
 */
abstract contract BaseDopplerHook is IDopplerHook {
    /// @notice Address of the DopplerHookInitializer contract
    address public immutable INITIALIZER;

    /// @notice Restricts the caller to the DopplerHookInitializer contract
    modifier onlyInitializer() {
        require(msg.sender == INITIALIZER, SenderNotInitializer());
        _;
    }

    /**
     * @param initializer Address of the DopplerHookInitializer contract
     */
    constructor(address initializer) {
        INITIALIZER = initializer;
    }

    /// @inheritdoc IDopplerHook
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external onlyInitializer {
        _onInitialization(asset, key, data);
    }

    /// @inheritdoc IDopplerHook
    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) external onlyInitializer {
        _onSwap(sender, key, params, balanceDelta, data);
    }

    /// @inheritdoc IDopplerHook
    function onGraduation(address asset, PoolKey calldata key, bytes calldata data) external onlyInitializer {
        _onGraduation(asset, key, data);
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
    ) internal virtual { }

    /// @dev Internal function to be overridden for graduation logic
    function _onGraduation(address asset, PoolKey calldata key, bytes calldata data) internal virtual { }
}
