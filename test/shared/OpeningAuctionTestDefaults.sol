pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";

library OpeningAuctionTestDefaults {
    uint256 internal constant DEFAULT_INCENTIVE_SHARE_BPS = 1000;
    uint24 internal constant DEFAULT_FEE = 3000;
    uint128 internal constant DEFAULT_MIN_LIQUIDITY = 1e15;
    uint256 internal constant DEFAULT_SHARE_TO_AUCTION_BPS = 10_000;

    function hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function defaultConfig(
        uint256 auctionDuration,
        int24 minAcceptableTickToken0,
        int24 minAcceptableTickToken1,
        int24 tickSpacing
    ) internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: auctionDuration,
            minAcceptableTickToken0: minAcceptableTickToken0,
            minAcceptableTickToken1: minAcceptableTickToken1,
            incentiveShareBps: DEFAULT_INCENTIVE_SHARE_BPS,
            tickSpacing: tickSpacing,
            fee: DEFAULT_FEE,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            shareToAuctionBps: DEFAULT_SHARE_TO_AUCTION_BPS
        });
    }
}
