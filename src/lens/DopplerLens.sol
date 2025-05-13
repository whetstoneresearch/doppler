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

struct DopplerLensReturnData {
    uint256 numSlugs;
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
            console.logBytes(reason);
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
            positions[2 + i] =
                Position({ tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, salt: uint8(2 + i) });
        }
        returnData.numSlugs = pdSlugCount + 2;
        returnData.positions = positions;
        returnData.sqrtPriceX96 = sqrtPriceX96;
        returnData.tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        console.log("returnData.numSlugs", returnData.numSlugs);
        console.log("returnData.sqrtPriceX96", returnData.sqrtPriceX96);
        console.log("returnData.tick", returnData.tick);
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
    ) internal returns (DopplerLensReturnData memory returnData) {
        if (reason.parseSelector() != DopplerLensData.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        assembly ("memory-safe") {
            // Get the data offset (32 bytes after selector)
            let dataOffset := mload(add(reason, 0x24))

            // Copy the struct data
            let dataPtr := add(reason, add(0x24, dataOffset))
            let returnDataPtr := returnData

            // Copy first three fields
            let numSlugs := mload(dataPtr)
            mstore(returnDataPtr, numSlugs)
            log2(0, 0, "numSlugs:", numSlugs)

            let sqrtPriceX96 := mload(add(dataPtr, 0x20))
            mstore(add(returnDataPtr, 0x20), sqrtPriceX96)
            log2(0, 0, "sqrtPriceX96:", sqrtPriceX96)

            let tick := mload(add(dataPtr, 0x40))
            mstore(add(returnDataPtr, 0x40), tick)
            log2(0, 0, "tick:", tick)

            // Get positions array offset
            let positionsOffset := mload(add(dataPtr, 0x60))
            log2(0, 0, "positionsOffset:", positionsOffset)

            let positionsData := add(dataPtr, positionsOffset)
            log2(0, 0, "positionsData:", positionsData)

            // Copy positions array length
            let numPositions := mload(positionsData)
            log2(0, 0, "numPositions:", numPositions)
            mstore(add(returnDataPtr, 0x60), numPositions)

            // Copy positions array data
            let positionsPtr := add(returnDataPtr, 0x80)
            let positionsDataPtr := add(positionsData, 0x20)
            log2(0, 0, "positionsPtr:", positionsPtr)
            log2(0, 0, "positionsDataPtr:", positionsDataPtr)
            mstore(add(returnDataPtr, 0xa0), positionsPtr)

            // Copy each position
            let amount0 := 0
            let amount1 := 0
            for { let i := 0 } lt(i, numPositions) { i := add(i, 1) } {
                // Each position is 128 bytes (4 * 32 bytes) in the ABI encoding
                let posPtr := add(positionsDataPtr, mul(i, 0x80))
                let structPtr := add(positionsPtr, mul(i, 0x20))

                // Extract and store each field
                // tickLower (3 bytes)
                let tickLower := signextend(2, mload(posPtr))
                mstore(structPtr, tickLower)

                // tickUpper (3 bytes)
                let tickUpper := signextend(2, mload(add(posPtr, 0x20)))
                mstore(add(structPtr, 0x03), tickUpper)
                // liquidity (16 bytes)
                let liquidity := mload(add(posPtr, 0x40))
                mstore(add(structPtr, 0x06), liquidity)
                log2(0, 0, "liquidity:", liquidity)

                // salt (1 byte)
                let salt := mload(add(posPtr, 0x60))
                mstore(add(structPtr, 0x16), salt)
                log2(0, 0, "salt:", salt)
            }
        }
        console.logBytes(abi.encode(returnData));
    }
}
