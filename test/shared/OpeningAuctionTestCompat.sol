// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";

/// @notice Test-only compatibility shim for removed OpeningAuction convenience views.
/// @dev Keeps test surface stable while production contract stays size-optimized.
abstract contract OpeningAuctionTestCompat is OpeningAuction {
    uint8 internal constant _TICK_SUM_WEIGHTED = 0;
    uint8 internal constant _TICK_SUM_ACCUMULATED = 1;

    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) { }

    function minAcceptableTick() public view returns (int24) {
        return _auctionPriceLimitTick();
    }

    function isInRange(uint256 positionId) public view returns (bool) {
        (AuctionPosition memory pos, bool exists) = _loadPosition(positionId);
        if (!exists) return false;

        int24 refTick;
        if (phase == AuctionPhase.Settled) {
            refTick = clearingTick;
        } else if (phase == AuctionPhase.Active || phase == AuctionPhase.Closed) {
            refTick = estimatedClearingTick;
        } else {
            return false;
        }

        if (isToken0) {
            return refTick < pos.tickUpper;
        }
        return refTick >= pos.tickLower;
    }

    function getPositionAccumulatedTime(uint256 positionId) public view returns (uint256 earnedSeconds) {
        uint256 earnedTimeX128 = _getPositionEarnedTimeX128(positionId);
        earnedSeconds = earnedTimeX128 >> 128;
    }

    function totalAccumulatedTime() public view returns (uint256) {
        return _sumActiveTickTimes(_TICK_SUM_ACCUMULATED);
    }

    function getPositionId(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        return positionKeyToId[key];
    }
}
