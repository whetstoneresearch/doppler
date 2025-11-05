// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IDook } from "src/interfaces/IDook.sol";

/// @notice Thrown when the msg.sender is not the Dook Multicurve Initializer contract
error SenderNotInitializer();

/// @notice Thrown when the msg.sender is not the Dook Multicurve Hook contract
error SenderNotHook();

uint256 constant ON_INITIALIZATION_FLAG = 1 << 0;
uint256 constant ON_SWAP_FLAG = 1 << 1;
uint256 constant ON_GRADUATION_FLAG = 1 << 2;

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

    /// @notice Address of the Dook Multicurve Hook contract
    address public immutable HOOK;

    /// @notice Restricts the caller to the Dook Multicurve Hook contract
    modifier onlyHook() {
        require(msg.sender == HOOK, SenderNotHook());
        _;
    }

    /// @notice Restricts the caller to the Dook Multicurve Initializer contract
    modifier onlyInitializer() {
        require(msg.sender == INITIALIZER, SenderNotInitializer());
        _;
    }

    /**
     * @param initializer Address of the Dook Multicurve Initializer contract
     * @param hook Address of the Dook Multicurve Hook contract
     */
    constructor(address initializer, address hook) {
        HOOK = hook;
        INITIALIZER = initializer;
    }

    /**
     * @notice Called upon pool initialization or when linking the Dook to an asset
     * @param asset Address of the asset being initialized in the Dook Multicurve Initializer
     * @param data Arbitrary data passed from the initializer to be consumed by the Dook
     */
    function onInitialization(address asset, bytes calldata data) external onlyInitializer {
        _onInitialization(asset, data);
    }

    /**
     * @notice Called upon every swap in a pool linked to this Dook
     * @param sender Address initiating the swap
     * @param key Key of the Uniswap V4 pool where the swap is occurring
     * @param params Swap paremters as defined in IPoolManager
     * @param data Arbitrary data passed from the hook to be consumed by the Dook
     */
    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external onlyHook {
        _onSwap(sender, key, params, data);
    }

    /**
     * @notice Called when a pool linked to this Dook graduates
     * @param asset Address of the asset being graduated in the Dook Multicurve Initializer
     * @param data Arbitrary data passed from the initializer to be consumed by the Dook
     */
    function onGraduation(address asset, bytes calldata data) external onlyInitializer {
        _onGraduation(asset, data);
    }

    /// @dev Internal function to be overridden for initialization logic
    function _onInitialization(address asset, bytes calldata data) internal virtual { }

    /// @dev Internal function to be overridden for swap logic
    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal virtual { }

    /// @dev Internal function to be overridden for graduation logic
    function _onGraduation(address asset, bytes calldata data) internal virtual { }
}
