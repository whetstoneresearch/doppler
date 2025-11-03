// SPDX-License-Identifier: BUSL-1.1

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IDook } from "src/interfaces/IDook.sol";

error SenderNotHook();

uint256 constant ON_INITIALIZATION_FLAG = 1 << 0;
uint256 constant ON_SWAP_FLAG = 1 << 1;
uint256 constant ON_GRADUATION_FLAG = 1 << 2;

abstract contract BaseDook is IDook {
    address public immutable HOOK;

    modifier onlyHook() {
        require(msg.sender == HOOK, SenderNotHook());
        _;
    }

    constructor(address hook) {
        HOOK = hook;
    }

    function onInitialization(address asset, bytes calldata data) external onlyHook {
        _onInitialization(asset, data);
    }

    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external onlyHook {
        _onSwap(sender, key, params, data);
    }

    function onGraduation(address asset, bytes calldata data) external onlyHook {
        _onGraduation(asset, data);
    }

    function _onInitialization(address asset, bytes calldata data) internal virtual { }

    function _onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal virtual { }

    function _onGraduation(address asset, bytes calldata data) internal virtual { }
}
