// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Position } from "src/types/Position.sol";

enum Actions {
    Mint,
    Burn,
    Collect
}

error CallerNotPoolManager();

error InvalidCallbackAction(uint8 action);

struct CallbackData {
    Actions action;
    PoolKey poolKey;
    Position[] positions;
}

abstract contract MiniV4Manager is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), CallerNotPoolManager());
        _;
    }

    constructor(
        IPoolManager poolManager_
    ) {
        poolManager = poolManager_;
    }

    /// @notice Handles the callback from the PoolManager
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        Actions action = callbackData.action;

        BalanceDelta balanceDelta;
        BalanceDelta totalFeesAccrued;

        if (action == Actions.Mint) {
            balanceDelta = _handleMint(callbackData.poolKey, callbackData.positions);
        } else if (action == Actions.Burn) {
            (balanceDelta, totalFeesAccrued) = _handleBurn(callbackData.poolKey, callbackData.positions);
        } else if (action == Actions.Collect) {
            totalFeesAccrued = _handleCollect(callbackData.poolKey, callbackData.positions);
        } else {
            revert InvalidCallbackAction(uint8(action));
        }

        _handleSettle(callbackData.poolKey, balanceDelta);
        return abi.encode(balanceDelta, totalFeesAccrued);
    }

    /// @dev Calls the PoolManager contract to mint the given positions of the given pool
    function _mint(PoolKey memory poolKey, Position[] memory positions) internal {
        poolManager.unlock(abi.encode(CallbackData({ action: Actions.Mint, poolKey: poolKey, positions: positions })));
    }

    function _burn(
        PoolKey memory poolKey,
        Position[] memory positions
    ) internal returns (BalanceDelta balanceDelta, BalanceDelta feesAccrued) {
        bytes memory data = poolManager.unlock(
            abi.encode(CallbackData({ action: Actions.Burn, poolKey: poolKey, positions: positions }))
        );
        (balanceDelta, feesAccrued) = abi.decode(data, (BalanceDelta, BalanceDelta));
    }

    function _collect(PoolKey memory poolKey, Position[] memory positions) internal returns (BalanceDelta totalFees) {
        bytes memory data = poolManager.unlock(
            abi.encode(CallbackData({ action: Actions.Collect, poolKey: poolKey, positions: positions }))
        );
        (totalFees) = abi.decode(data, (BalanceDelta));
    }

    /// @dev This function is not meant to be called directly! Its purpose is only to trigger the minting of the
    /// positions during the PoolManager callback call
    function _handleMint(
        PoolKey memory poolKey,
        Position[] memory positions
    ) internal returns (BalanceDelta balanceDelta) {
        uint256 length = positions.length;

        for (uint256 i; i != length; ++i) {
            Position memory pos = positions[i];
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: int128(pos.liquidity),
                salt: pos.salt // TODO: Not sure if we really need to set one
             });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, new bytes(0));
            balanceDelta = balanceDelta + delta;
        }
    }

    function _handleBurn(
        PoolKey memory poolKey,
        Position[] memory positions
    ) internal returns (BalanceDelta balanceDelta, BalanceDelta totalFeesAccrued) {
        uint256 length = positions.length;

        for (uint256 i; i != length; ++i) {
            Position memory pos = positions[i];
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int128(pos.liquidity),
                salt: pos.salt
            });

            (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(poolKey, params, new bytes(0));
            balanceDelta = balanceDelta + delta;
            totalFeesAccrued = totalFeesAccrued + feesAccrued;
        }
    }

    function _handleCollect(
        PoolKey memory poolKey,
        Position[] memory positions
    ) internal returns (BalanceDelta totalFees) {
        uint256 length = positions.length;

        for (uint256 i; i != length; ++i) {
            Position memory pos = positions[i];
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: 0,
                salt: pos.salt
            });

            (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(poolKey, params, new bytes(0));
            totalFees = totalFees + feesAccrued;
        }
    }

    function _handleSettle(
        PoolKey memory poolKey,
        BalanceDelta delta
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (delta.amount0() > 0) {
            poolManager.take(poolKey.currency0, address(this), uint128(delta.amount0()));
        }

        if (delta.amount1() > 0) {
            poolManager.take(poolKey.currency1, address(this), uint128(delta.amount1()));
        }

        if (delta.amount0() < 0) {
            poolManager.sync(poolKey.currency0);

            poolKey.currency0.transfer(address(poolManager), uint128(-delta.amount0()));
            poolManager.settle();
        }

        if (delta.amount1() < 0) {
            poolManager.sync(poolKey.currency1);
            poolKey.currency1.transfer(address(poolManager), uint128(-delta.amount1()));
            poolManager.settle();
        }
    }
}
