// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ParseBytes } from "@v4-core/libraries/ParseBytes.sol";
import { SqrtPriceMath } from "@v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BaseV4Quoter } from "@v4-periphery/base/BaseV4Quoter.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { Doppler, Position } from "src/initializers/Doppler.sol";

// Demarcates the id of the lower, upper, and price discovery slugs
bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

struct DopplerLensReturnData {
    uint160 sqrtPriceX96;
    uint256 amount0;
    uint256 amount1;
    int24 tick;
}

/// @title DopplerLensQuoter
/// @notice Supports quoting the tick for exact input or exact output swaps.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.

contract DopplerLensQuoter is BaseV4Quoter {
    using DopplerLensRevert for bytes;
    using DopplerLensRevert for DopplerLensReturnData;
    using SqrtPriceMath for *;

    IStateView public immutable stateView;

    constructor(IPoolManager poolManager_, IStateView stateView_) BaseV4Quoter(poolManager_) {
        stateView = stateView_;
    }

    function quoteDopplerLensData(
        IV4Quoter.QuoteExactSingleParams memory params
    ) external returns (DopplerLensReturnData memory returnData) {
        try poolManager.unlock(abi.encodeCall(this._quoteDopplerLensDataExactInputSingle, (params))) { }
        catch (bytes memory reason) {
            returnData = reason.parseDopplerLensData();
        }
    }

    /// @dev External function called within the _unlockCallback, to simulate a single-hop exact input swap, then revert with the result
    function _quoteDopplerLensDataExactInputSingle(
        IV4Quoter.QuoteExactSingleParams calldata params
    ) external selfOnly returns (bytes memory) {
        _swap(params.poolKey, params.zeroForOne, -int256(int128(params.exactAmount)), params.hookData);

        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(params.poolKey.toId());
        Doppler doppler = Doppler(payable(address(params.poolKey.hooks)));
        DopplerLensReturnData memory returnData;

        uint256 pdSlugCount = doppler.numPDSlugs();
        Position[] memory positions = new Position[](pdSlugCount + 2);

        bool isToken0 = doppler.isToken0();

        uint256 amount0;
        uint256 amount1;
        (int24 tickLower0, int24 tickUpper0, uint128 liquidity0,) = doppler.positions(LOWER_SLUG_SALT);
        positions[0] = Position({
            tickLower: isToken0 ? tickLower0 : tickUpper0,
            tickUpper: isToken0 ? tickUpper0 : tickLower0,
            liquidity: liquidity0,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });

        (int24 tickLower1, int24 tickUpper1, uint128 liquidity1,) = doppler.positions(UPPER_SLUG_SALT);
        positions[1] = Position({
            tickLower: isToken0 ? tickLower1 : tickUpper1,
            tickUpper: isToken0 ? tickUpper1 : tickLower1,
            liquidity: liquidity1,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });

        for (uint256 i; i < pdSlugCount; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 salt) =
                doppler.positions(bytes32(uint256(DISCOVERY_SLUG_SALT) + i));
            positions[2 + i] = Position({
                tickLower: isToken0 ? tickLower : tickUpper,
                tickUpper: isToken0 ? tickUpper : tickLower,
                liquidity: liquidity,
                salt: uint8(salt)
            });
        }

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        for (uint256 i; i < positions.length; i++) {
            if (tick < positions[i].tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                amount0 += SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtPriceAtTick(positions[i].tickLower),
                    TickMath.getSqrtPriceAtTick(positions[i].tickUpper),
                    positions[i].liquidity,
                    false
                );
            } else if (tick < positions[i].tickUpper) {
                amount0 += SqrtPriceMath.getAmount0Delta(
                    sqrtPriceX96, TickMath.getSqrtPriceAtTick(positions[i].tickUpper), positions[i].liquidity, false
                );

                amount1 += SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(positions[i].tickLower), sqrtPriceX96, positions[i].liquidity, false
                );
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
                amount1 += SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(positions[i].tickLower),
                    TickMath.getSqrtPriceAtTick(positions[i].tickUpper),
                    positions[i].liquidity,
                    false
                );
            }
        }
        returnData.amount0 = amount0;
        returnData.amount1 = amount1;
        returnData.tick = tick;
        returnData.sqrtPriceX96 = sqrtPriceX96;
        returnData.revertDopplerLensData();
    }
}

library DopplerLensRevert {
    using DopplerLensRevert for bytes;
    using ParseBytes for bytes;

    /// @notice Error thrown when invalid revert bytes are thrown by the quote
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice Error thrown containing the sqrtPriceX96 as the data, to be caught and parsed later
    error DopplerLensData(DopplerLensReturnData returnData);

    function revertDopplerLensData(DopplerLensReturnData memory returnData) internal pure {
        revert DopplerLensData(returnData);
    }

    /// @notice Reverts using the revertData as the reason
    /// @dev To bubble up both the valid QuoteSwap(amount) error, or an alternative error thrown during simulation
    function bubbleReason(bytes memory revertData) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 0x20): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice Validates whether a revert reason is a valid doppler lens data or not
    /// if valid, it decodes the data to return. Otherwise it reverts.
    function parseDopplerLensData(bytes memory reason) internal pure returns (DopplerLensReturnData memory returnData) {
        if (reason.parseSelector() != DopplerLensData.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        assembly ("memory-safe") {
            // The data starts right after the selector (4 bytes)
            let dataPtr := add(reason, 0x24)
            let returnDataPtr := returnData

            // Copy fields in the correct order
            mstore(returnDataPtr, mload(dataPtr)) // sqrtPriceX96
            mstore(add(returnDataPtr, 0x20), mload(add(dataPtr, 0x20))) // amount0
            mstore(add(returnDataPtr, 0x40), mload(add(dataPtr, 0x40))) // amount1
            mstore(add(returnDataPtr, 0x60), mload(add(dataPtr, 0x60))) // tick
        }
    }
}
