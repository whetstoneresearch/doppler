// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { SafeCast } from "@v4-core/libraries/SafeCast.sol";
import { IPoolManager, PoolKey, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Position } from "src/types/Position.sol";

/// @dev Possible actions passed through the `unlockCallback` function
enum Actions {
    Mint,
    Burn,
    Collect
}

/// @dev Thrown when the caller is not the `PoolManager` contract
error CallerNotPoolManager();

/// @dev Thrown when the given action in the `unlockCallback` function is invalid
error InvalidCallbackAction(uint8 action);

/**
 * @dev Struct used to pass data via the `unlockCallback` function
 * @param action Action to perform in the callback
 * @param poolKey Key of the Uniswap V4 pool where the action will be performed
 * @param positions Array of positions to update in the callback
 */
struct CallbackData {
    Actions action;
    PoolKey poolKey;
    Position[] positions;
}

/**
 * @title MiniV4Manager
 * @author Whetstone Research
 * @dev Base contract implementing different actions with the Uniswap V4 `PoolManager` and allowing an inheriting
 * child to mint or burn positions and collect fees from them
 * @custom:security-contact security@whetstone.cc
 */
abstract contract MiniV4Manager is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using SafeCast for uint256;

    /// @notice Address of Uniswap V4 `PoolManager` contract
    IPoolManager public immutable poolManager;

    /// @dev Requires that the `msg.sender` is the stored `poolManager`
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), CallerNotPoolManager());
        _;
    }

    /// @param poolManager_ Address of Uniswap V4 `PoolManager` contract
    constructor(
        IPoolManager poolManager_
    ) {
        poolManager = poolManager_;
    }

    /// @inheritdoc IUnlockCallback
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

    /**
     * @dev Calls the `PoolManager` to mint the given `positions` from the specified `poolKey` pool
     * @param poolKey Key of the Uniswap V4 pool to mint from
     * @param positions Array of `Position` struct to mint
     */
    function _mint(PoolKey memory poolKey, Position[] memory positions) internal {
        poolManager.unlock(abi.encode(CallbackData({ action: Actions.Mint, poolKey: poolKey, positions: positions })));
    }

    /**
     * @dev Calls the `PoolManager` to burn the given `positions` from the specified `poolKey` pool
     * @param poolKey Key of the Uniswap V4 pool to burn from
     * @param positions Array of `Position` struct to burn
     * @return balanceDelta Balances denominated in `token0` and `token1` retrieved from the burnt positions
     * @return feesAccrued Fees accrued from the burnt positions since last collection (included in `balanceDelta`)
     */
    function _burn(
        PoolKey memory poolKey,
        Position[] memory positions
    ) internal returns (BalanceDelta balanceDelta, BalanceDelta feesAccrued) {
        bytes memory data = poolManager.unlock(
            abi.encode(CallbackData({ action: Actions.Burn, poolKey: poolKey, positions: positions }))
        );
        (balanceDelta, feesAccrued) = abi.decode(data, (BalanceDelta, BalanceDelta));
    }

    /**
     * @dev Calls the `PoolManager` to collect fees earned by the given `positions` in the specified `poolKey` pool
     * @param poolKey Key of the Uniswap V4 pool to collect fees from
     * @param positions Array of `Position` struct
     * @return totalFees Fees collected from the given positions, denominated in `token0` and `token1`
     */
    function _collect(PoolKey memory poolKey, Position[] memory positions) internal returns (BalanceDelta totalFees) {
        bytes memory data = poolManager.unlock(
            abi.encode(CallbackData({ action: Actions.Collect, poolKey: poolKey, positions: positions }))
        );
        (totalFees) = abi.decode(data, (BalanceDelta));
    }

    /**
     * @dev Handles the minting of the positions during the `PoolManager` callback call
     * @param poolKey Key of the Uniswap V4 pool to mint from
     * @param positions Array of `Position` struct to mint
     * @return balanceDelta Current delta of negative balances denominated in `token0` and `token1`
     */
    function _handleMint(
        PoolKey memory poolKey,
        Position[] memory positions
    ) private returns (BalanceDelta balanceDelta) {
        uint256 length = positions.length;

        for (uint256 i; i != length; ++i) {
            Position memory pos = positions[i];
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: pos.liquidity.toInt256(),
                salt: pos.salt // TODO: Not sure if we really need to set one
             });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, new bytes(0));
            balanceDelta = balanceDelta + delta;
        }
    }

    /**
     * @dev Handles the burning of the positions during the `PoolManager` callback call
     * @param poolKey Key of the Uniswap V4 pool to burn from
     * @param positions Array of `Position` struct to burn
     * @return balanceDelta Current delta of positive balances denominated in `token0` and `token1`
     * @return totalFeesAccrued Fees accrued from the burnt positions since last collection (included in `balanceDelta`)
     */
    function _handleBurn(
        PoolKey memory poolKey,
        Position[] memory positions
    ) private returns (BalanceDelta balanceDelta, BalanceDelta totalFeesAccrued) {
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

    /**
     * @dev Handles the collection of the fees during the `PoolManager` callback call
     * @param poolKey Key of the Uniswap V4 pool to collect fees from
     * @param positions Array of `Position` struct to collect fees from
     * @return totalFees Fees collected from the positions
     */
    function _handleCollect(
        PoolKey memory poolKey,
        Position[] memory positions
    ) private returns (BalanceDelta totalFees) {
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

    /**
     * @dev Handles the settlement of the balances during the `PoolManager` callback call
     * @param poolKey Key of the Uniswap V4 pool, used to retrieve the currencies
     * @param delta Current balances to settle denominated in `currency0` and `currency1`
     */
    function _handleSettle(PoolKey memory poolKey, BalanceDelta delta) private {
        if (delta.amount0() > 0) {
            poolManager.take(poolKey.currency0, address(this), delta.amount0().toUint128());
        }

        if (delta.amount1() > 0) {
            poolManager.take(poolKey.currency1, address(this), delta.amount1().toUint128());
        }

        if (delta.amount0() < 0) {
            _pay(poolKey.currency0, poolManager, uint256(-int256(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            _pay(poolKey.currency1, poolManager, uint256(-int256(delta.amount1())));
        }
    }

    /**
     * @dev Pays a debt to the `PoolManager` contract, either using native ETH or an arbitrary ERC20 token
     * @param currency Currency to pay, pass address zero for native ETH
     * @param manager Address of the `PoolManager`
     * @param amount Amount to pay
     */
    function _pay(Currency currency, IPoolManager manager, uint256 amount) private {
        if (currency.isAddressZero()) {
            manager.settle{ value: amount }();
        } else {
            manager.sync(currency);
            currency.transfer(address(manager), amount);
            manager.settle();
        }
    }
}
