// TODO: Add license
pragma solidity 0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";

contract Doppler is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
