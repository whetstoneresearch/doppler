// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IDook } from "src/interfaces/IDook.sol";

/// @dev Flag for the `onInitialization` callback
uint256 constant ON_INITIALIZATION_FLAG = 1 << 0;

/// @dev Flag for the `onSwap` callback
uint256 constant ON_SWAP_FLAG = 1 << 1;

/// @dev Flag for the `onGraduation` callback
uint256 constant ON_GRADUATION_FLAG = 1 << 2;

/// @notice Thrown when the msg.sender is not the Dook Multicurve Initializer contract
error SenderNotInitializer();

/// @notice Thrown when the msg.sender is not the Dook Multicurve Hook contract
error SenderNotHook();

/**
 * @title Doppler Hook Base Contract
 * @author Whetstone Research
 * @dev Base contract for the Doppler Hooks, here is implemented access control for the different
 * callback functions along with virtual internal functions to be overridden by child contracts
 * @custom:security-contact security@whetstone.cc
 */
abstract contract BaseDook is IDook {
    /// @notice Address of the Dook Multicurve Initializer contract
    address public immutable INITIALIZER;

    /// @notice Restricts the caller to the Dook Multicurve Initializer contract
    modifier onlyInitializer() {
        require(msg.sender == INITIALIZER, SenderNotInitializer());
        _;
    }

    /**
     * @param initializer Address of the Dook Multicurve Initializer contract
     */
    constructor(address initializer) {
        INITIALIZER = initializer;
    }

    /**
     * @notice Called upon pool initialization or when linking the Dook to an asset
     * @param asset Address of the asset being initialized in the Dook Multicurve Initializer
     * @param data Arbitrary data passed from the initializer to be consumed by the Dook
     */
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external onlyInitializer {
        _onInitialization(asset, key, data);
    }

    /**
     * @notice Called upon every swap in a pool linked to this Dook
     * @param sender Address initiating the swap
     * @param key Key of the Uniswap V4 pool where the swap is occurring
     * @param params Swap paremters as defined in IPoolManager
     * @param balanceDelta Balance delta resulting from the swap
     * @param data Arbitrary data passed from the hook to be consumed by the Dook
     */
    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) external onlyInitializer {
        _onSwap(sender, key, params, balanceDelta, data);
    }

    /**
     * @notice Called when a pool linked to this Dook graduates
     * @param asset Address of the asset being graduated in the Dook Multicurve Initializer
     * @param key Key of the Uniswap V4 pool graduating
     * @param data Arbitrary data passed from the initializer to be consumed by the Dook
     */
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
