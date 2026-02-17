// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";
import { OpeningAuctionTestDefaults } from "test/shared/OpeningAuctionTestDefaults.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation for testing
contract OpeningAuctionTestImpl is OpeningAuctionTestCompat {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuctionTestCompat(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract ConstructorTest is Test {
    IPoolManager manager;
    address initializer = address(0xbeef);

    function setUp() public {
        manager = new PoolManager(address(this));
    }

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionTestDefaults.defaultConfig(1 days, -99_960, -99_960, 60);
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
        uint256 expectedIncentives = (totalTokens * config.incentiveShareBps) / 10_000;
        assertEq(auction.incentiveTokensTotal(), expectedIncentives);
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
        uint256 expectedIncentives = 150_000 ether;
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

    function test_constructor_AllowsInvalidAuctionDuration_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.auctionDuration = 0;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        assertEq(auction.auctionDuration(), 0);
    }

    function test_constructor_AllowsInvalidIncentiveShareBps_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.incentiveShareBps = 10_001;

        uint256 totalTokens = 1_000_000 ether;
        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            totalTokens,
            config
        );

        uint256 expectedIncentives = (totalTokens * config.incentiveShareBps) / 10_000;
        assertEq(auction.incentiveTokensTotal(), expectedIncentives);
    }

    function test_constructor_AllowsInvalidTickSpacing_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.tickSpacing = 0;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        assertEq(auction.nextPositionId(), 1);
    }

    function test_constructor_AllowsInvalidMinLiquidity_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minLiquidity = 0;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        assertEq(auction.minLiquidity(), 0);
    }

    function test_constructor_AllowsMisalignedMinAcceptableTick_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken0 = -99_961;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        vm.prank(initializer);
        auction.setIsToken0(true);
        assertEq(auction.minAcceptableTick(), config.minAcceptableTickToken0);
    }

    function test_constructor_AllowsMisalignedMinAcceptableTickToken1_ConfigValidatedByInitializer() public {
        OpeningAuctionConfig memory config = getDefaultConfig();
        config.minAcceptableTickToken1 = -99_961;

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl(
            manager,
            initializer,
            1_000_000 ether,
            config
        );

        vm.prank(initializer);
        auction.setIsToken0(false);
        assertEq(auction.minAcceptableTick(), -config.minAcceptableTickToken1);
    }
}
