// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { PathKey } from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import { QuoterRevert } from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import { BaseV4Quoter } from "@uniswap/v4-periphery/src/base/BaseV4Quoter.sol";
import { IStateView } from "@uniswap/v4-periphery/src/lens/StateView.sol";
import { ParseBytes } from "@uniswap/v4-core/src/libraries/ParseBytes.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title DopplerLensQuoter
/// @notice Supports quoting the tick for exact input or exact output swaps.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.

contract DopplerLensQuoter is BaseV4Quoter {
    using DopplerLensRevert for *;

    IStateView public immutable stateView;

    constructor(IPoolManager _poolManager, IStateView _stateView) BaseV4Quoter(_poolManager) {
        stateView = _stateView;
    }

    function quoteDopplerLensData(
        IV4Quoter.QuoteExactSingleParams memory params
    ) external returns (uint160 sqrtPriceX96, int24 tick) {
        try poolManager.unlock(abi.encodeCall(this._quoteDopplerLensDataExactInputSingle, (params))) { }
        catch (bytes memory reason) {
            sqrtPriceX96 = reason.parseDopplerLensData();
            tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        }
    }

    /// @dev external function called within the _unlockCallback, to simulate a single-hop exact input swap, then revert with the result
    function _quoteDopplerLensDataExactInputSingle(
        IV4Quoter.QuoteExactSingleParams calldata params
    ) external selfOnly returns (bytes memory) {
        _swap(params.poolKey, params.zeroForOne, -int256(int128(params.exactAmount)), params.hookData);

        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(params.poolKey.toId());
        sqrtPriceX96.revertDopplerLensData();
    }
}

library DopplerLensRevert {
    using DopplerLensRevert for bytes;
    using ParseBytes for bytes;

    /// @notice error thrown when invalid revert bytes are thrown by the quote
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice error thrown containing the sqrtPriceX96 as the data, to be caught and parsed later
    error DopplerLensData(uint160 sqrtPriceX96);

    function revertDopplerLensData(
        uint160 sqrtPriceX96
    ) internal pure {
        revert DopplerLensData(sqrtPriceX96);
    }

    /// @notice reverts using the revertData as the reason
    /// @dev to bubble up both the valid QuoteSwap(amount) error, or an alternative error thrown during simulation
    function bubbleReason(
        bytes memory revertData
    ) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 0x20): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice validates whether a revert reason is a valid doppler lens data or not
    /// if valid, it decodes the sqrtPriceX96 to return. Otherwise it reverts.
    function parseDopplerLensData(
        bytes memory reason
    ) internal pure returns (uint160 sqrtPriceX96) {
        // If the error doesnt start with DopplerLensData, we know this isnt valid data to parse
        // Instead it is another revert that was triggered somewhere in the simulation
        if (reason.parseSelector() != DopplerLensData.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of DopplerLensData
        // reason+0x24 -> reason+0x43 is the sqrtPriceX96
        assembly ("memory-safe") {
            sqrtPriceX96 := mload(add(reason, 0x24))
        }
    }
}
