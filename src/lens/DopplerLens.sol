// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";
import { BaseV4Quoter } from "@v4-periphery/base/BaseV4Quoter.sol";
import { IStateView } from "@v4-periphery/interfaces/IStateView.sol";
import { ParseBytes } from "@v4-core/libraries/ParseBytes.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

/// @title DopplerLensQuoter
/// @notice Supports quoting the tick for exact input or exact output swaps.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
contract DopplerLensQuoter is BaseV4Quoter {
    using DopplerLensRevert for bytes;
    using DopplerLensRevert for uint160;

    IStateView public immutable stateView;

    constructor(IPoolManager poolManager_, IStateView stateView_) BaseV4Quoter(poolManager_) {
        stateView = stateView_;
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

    /// @dev External function called within the _unlockCallback, to simulate a single-hop exact input swap, then revert with the result
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

    /// @notice Error thrown when invalid revert bytes are thrown by the quote
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice Error thrown containing the sqrtPriceX96 as the data, to be caught and parsed later
    error DopplerLensData(uint160 sqrtPriceX96);

    function revertDopplerLensData(
        uint160 sqrtPriceX96
    ) internal pure {
        revert DopplerLensData(sqrtPriceX96);
    }

    /// @notice Reverts using the revertData as the reason
    /// @dev To bubble up both the valid QuoteSwap(amount) error, or an alternative error thrown during simulation
    function bubbleReason(
        bytes memory revertData
    ) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 0x20): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice Validates whether a revert reason is a valid doppler lens data or not
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
