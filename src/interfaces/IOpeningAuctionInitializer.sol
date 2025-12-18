// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/// @notice Status of an opening auction
enum OpeningAuctionStatus {
    Uninitialized,
    AuctionActive,
    DopplerActive,
    Exited
}

/// @notice State of an opening auction
struct OpeningAuctionState {
    address numeraire;
    uint256 auctionStartTime;
    uint256 auctionEndTime;
    uint256 auctionTokens;
    uint256 dopplerTokens;
    OpeningAuctionStatus status;
    address openingAuctionHook;
    address dopplerHook;
    PoolKey openingAuctionPoolKey;
    bytes dopplerInitData;
    bool isToken0;
}

/// @title IOpeningAuctionInitializer
/// @notice Interface for the Opening Auction Initializer
interface IOpeningAuctionInitializer is IPoolInitializer {
    /// @notice Emitted when an opening auction transitions to Doppler
    event AuctionCompleted(
        address indexed asset,
        int24 clearingTick,
        uint256 tokensSold,
        uint256 proceeds
    );

    /// @notice Complete the auction and transition to Doppler
    /// @param asset The asset token address
    function completeAuction(address asset) external;

    /// @notice Get the state for an asset's opening auction
    /// @param asset The asset token address
    /// @return state The opening auction state
    function getState(address asset) external view returns (OpeningAuctionState memory state);

    /// @notice Get the Doppler hook address for an asset
    /// @param asset The asset token address
    /// @return The Doppler hook address
    function getDopplerHook(address asset) external view returns (address);

    /// @notice Get the Opening Auction hook address for an asset
    /// @param asset The asset token address
    /// @return The Opening Auction hook address
    function getOpeningAuctionHook(address asset) external view returns (address);
}
