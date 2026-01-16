// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation for testing
contract OpeningAuctionTestImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract ConstructorTest is Test {
    IPoolManager manager;
    address initializer = address(0xbeef);

    function setUp() public {
        manager = new PoolManager(address(this));
    }

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -99_960, // Aligned to tick spacing 60
            minAcceptableTickToken1: -99_960,
            incentiveShareBps: 1000, // 10%
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });
    }

    function test_constructor_SetsParametersCorrectly() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        uint256 totalTokens = 1_000_000 ether;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            totalTokens,
            config
        );

        vm.prank(initializer);
        auction.setIsToken0(true);

        assertEq(auction.auctionDuration(), config.auctionDuration);
        assertEq(auction.minAcceptableTick(), config.minAcceptableTickToken0);
        assertEq(auction.incentiveShareBps(), config.incentiveShareBps);
        assertEq(auction.totalAuctionTokens(), totalTokens);
        assertEq(auction.initializer(), initializer);
    }

    function test_constructor_CalculatesIncentiveTokensCorrectly() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 1500; // 15%
        uint256 totalTokens = 1_000_000 ether;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            totalTokens,
            config
        );

        // 15% of 1_000_000 = 150_000
        uint256 expectedIncentives = (totalTokens * 1500) / 10_000;
        assertEq(auction.incentiveTokensTotal(), expectedIncentives);
    }

    function test_constructor_StartsWithNotStartedPhase() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        assertEq(uint8(auction.phase()), uint8(AuctionPhase.NotStarted));
    }

    function test_constructor_StartsWithPositionIdOne() public {
        OpeningAuctionConfig memory config = getDefaultConfig();

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        assertEq(auction.nextPositionId(), 1);
    }

    function test_constructor_RevertsInvalidAuctionDuration() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.auctionDuration = 0;

        vm.expectRevert(abi.encodeWithSignature("InvalidAuctionDuration()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }

    function test_constructor_RevertsInvalidIncentiveShareBps() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 10_001;

        vm.expectRevert(abi.encodeWithSignature("InvalidIncentiveShareBps()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }

    function test_constructor_RevertsInvalidTickSpacing() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.tickSpacing = 0;

        vm.expectRevert(abi.encodeWithSignature("InvalidTickSpacing()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }

    function test_constructor_RevertsInvalidMinLiquidity() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minLiquidity = 0;

        vm.expectRevert(abi.encodeWithSignature("InvalidMinLiquidity()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }

    function test_constructor_RevertsMisalignedMinAcceptableTick() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = -99_961;

        vm.expectRevert(abi.encodeWithSignature("InvalidMinAcceptableTick()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }

    function test_constructor_RevertsMisalignedMinAcceptableTickToken1() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken1 = -99_961;

        vm.expectRevert(abi.encodeWithSignature("InvalidMinAcceptableTick()"));
        new OpeningAuctionTestImpl(manager, initializer, 1_000_000 ether, config);
    }
}
