// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { AuctionPhase, AuctionPosition, TickTimeState } from "src/interfaces/IOpeningAuction.sol";

interface IOpeningAuctionLensTarget {
    function positions(uint256 positionId) external view returns (AuctionPosition memory);
    function phase() external view returns (AuctionPhase);
    function auctionEndTime() external view returns (uint256);
    function clearingTick() external view returns (int24);
    function estimatedClearingTick() external view returns (int24);
    function isToken0() external view returns (bool);
    function minAcceptableTickToken0() external view returns (int24);
    function minAcceptableTickToken1() external view returns (int24);
    function positionKeyToId(bytes32 positionKey) external view returns (uint256);
    function tickTimeStates(int24 tick) external view returns (TickTimeState memory);
    function positionHarvestedTimeX128(uint256 positionId) external view returns (uint256);
}

/// @notice Helper read-only views for OpeningAuction.
contract OpeningAuctionLens {
    /// @notice Get the pool-space price limit tick enforced by swaps.
    function minAcceptableTick(IOpeningAuctionLensTarget auction) external view returns (int24) {
        return auction.isToken0() ? auction.minAcceptableTickToken0() : -auction.minAcceptableTickToken1();
    }

    /// @notice Check if a position is currently in range.
    function isInRange(IOpeningAuctionLensTarget auction, uint256 positionId) external view returns (bool) {
        AuctionPosition memory pos = auction.positions(positionId);
        if (pos.owner == address(0)) return false;

        int24 refTick;
        AuctionPhase phase = auction.phase();
        if (phase == AuctionPhase.Settled) {
            refTick = auction.clearingTick();
        } else if (phase == AuctionPhase.Active || phase == AuctionPhase.Closed) {
            refTick = auction.estimatedClearingTick();
        } else {
            return false;
        }

        if (auction.isToken0()) {
            return refTick < pos.tickUpper;
        }
        return refTick >= pos.tickLower;
    }

    /// @notice Helper to derive a position ID from key data.
    function getPositionId(
        IOpeningAuctionLensTarget auction,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        return auction.positionKeyToId(key);
    }

    /// @notice Get a position's earned time (liquidity-weighted seconds).
    function getPositionAccumulatedTime(IOpeningAuctionLensTarget auction, uint256 positionId)
        external
        view
        returns (uint256 earnedSeconds)
    {
        AuctionPosition memory pos = auction.positions(positionId);
        if (pos.owner == address(0)) return 0;

        uint256 earnedTimeX128 = auction.positionHarvestedTimeX128(positionId);

        if (pos.liquidity > 0) {
            TickTimeState memory tickState = auction.tickTimeStates(pos.tickLower);
            uint256 tickAccumulatorX128 = tickState.accumulatedSecondsX128;

            if (tickState.isInRange && tickState.lastUpdateTime > 0) {
                AuctionPhase phase = auction.phase();
                uint256 endTime = (phase == AuctionPhase.Settled || phase == AuctionPhase.Closed)
                    ? auction.auctionEndTime()
                    : (block.timestamp > auction.auctionEndTime() ? auction.auctionEndTime() : block.timestamp);
                if (endTime > tickState.lastUpdateTime) {
                    tickAccumulatorX128 += (endTime - tickState.lastUpdateTime) << 128;
                }
            }

            if (tickAccumulatorX128 > pos.rewardDebtX128) {
                earnedTimeX128 += (tickAccumulatorX128 - pos.rewardDebtX128) * uint256(pos.liquidity);
            }
        }

        earnedSeconds = earnedTimeX128 >> 128;
    }
}
