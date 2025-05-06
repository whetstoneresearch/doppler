// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { BaseV4Quoter } from "@v4-periphery/base/BaseV4Quoter.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { ParseBytes } from "@v4-core/libraries/ParseBytes.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Doppler, Position } from "src/Doppler.sol";
import "forge-std/console.sol";

// Demarcates the id of the lower, upper, and price discovery slugs
bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

// Number of default slugs
uint256 constant NUM_DEFAULT_SLUGS = 3;

struct DopplerLensReturnData {
    uint160 sqrtPriceX96;
    int24 tick;
    Position[] positions;
}

/// @title DopplerLensQuoter
/// @notice Supports quoting the tick for exact input or exact output swaps.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
contract DopplerLensQuoter is BaseV4Quoter {
    using DopplerLensRevert for bytes;
    using DopplerLensRevert for DopplerLensReturnData;

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
            console.log("tick", returnData.tick);
            console.log("sqrtPriceX96", returnData.sqrtPriceX96);
            console.log("positions", returnData.positions.length);
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
        Position[] memory positions = new Position[](NUM_DEFAULT_SLUGS - 1 + pdSlugCount);

        (int24 tickLower0, int24 tickUpper0, uint128 liquidity0,) = doppler.positions(LOWER_SLUG_SALT);
        positions[0] = Position({
            tickLower: tickLower0,
            tickUpper: tickUpper0,
            liquidity: liquidity0,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });

        (int24 tickLower1, int24 tickUpper1, uint128 liquidity1,) = doppler.positions(UPPER_SLUG_SALT);
        positions[1] = Position({
            tickLower: tickLower1,
            tickUpper: tickUpper1,
            liquidity: liquidity1,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });

        for (uint256 i; i < pdSlugCount; i++) {
            (int24 tickLower, int24 tickUpper, uint128 liquidity,) =
                doppler.positions(bytes32(uint256(DISCOVERY_SLUG_SALT) + i));
            positions[NUM_DEFAULT_SLUGS - 1 + i] = Position({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                salt: uint8(NUM_DEFAULT_SLUGS + i)
            });
        }
        returnData.positions = positions;
        returnData.sqrtPriceX96 = sqrtPriceX96;
        returnData.tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

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

    function revertDopplerLensData(
        DopplerLensReturnData memory returnData
    ) internal pure {
        revert DopplerLensData(returnData);
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
    ) internal pure returns (DopplerLensReturnData memory returnData) {
        // If the error doesnt start with DopplerLensData, we know this isnt valid data to parse
        // Instead it is another revert that was triggered somewhere in the simulation
        if (reason.parseSelector() != DopplerLensData.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of DopplerLensData
        // reason+0x24 -> reason+0x43 is the sqrtPriceX96
        // reason+0x44 -> reason+0x47 is the tick
        // reason+0x48 -> reason+0x67 is the positions array length
        // reason+0x68 -> reason+0x87 is the positions array data pointer
        assembly ("memory-safe") {
            // Load sqrtPriceX96 (uint160)
            mstore(add(returnData, 0x00), shr(96, mload(add(reason, 0x24))))

            // Load tick (int24)
            mstore(add(returnData, 0x20), signextend(2, shr(232, mload(add(reason, 0x44)))))

            // Load positions array length
            let positionsLength := mload(add(reason, 0x48))
            mstore(add(returnData, 0x40), positionsLength)

            // Calculate positions array data pointer
            let positionsData := add(reason, 0x68)

            // Copy positions array data
            let positionsDataSize := mul(positionsLength, 0x20) // Each Position struct is 0x20 bytes
            let positionsDataEnd := add(positionsData, positionsDataSize)

            // Copy each position struct
            for { let i := 0 } lt(i, positionsLength) { i := add(i, 1) } {
                let posPtr := add(positionsData, mul(i, 0x20))
                let posData := mload(posPtr)
                mstore(add(add(returnData, 0x60), mul(i, 0x20)), posData)
            }
        }
    }
}
