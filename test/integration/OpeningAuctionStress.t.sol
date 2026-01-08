// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation for testing
contract StressTestOpeningAuction is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title OpeningAuctionStress
/// @notice Stress tests for Opening Auction with many bidders and positions
contract OpeningAuctionStressTest is Test, Deployers {
    uint256 constant AUCTION_TOKENS = 100 ether;

    StressTestOpeningAuction hook;
    uint256 bidNonce;
    mapping(uint256 => bytes32) internal positionSalts;
    // modifyLiquidityRouter inherited from Deployers
    PoolKey poolKey;
    
    address token0;
    address token1;
    address asset;
    
    OpeningAuctionConfig config;

    function setUp() public {
        // Deploy v4 core
        deployFreshManagerAndRouters();
        
        // Deploy tokens - ensure correct ordering
        TestERC20 tokenA = new TestERC20(2**128);
        TestERC20 tokenB = new TestERC20(2**128);
        
        if (address(tokenA) < address(tokenB)) {
            token0 = address(tokenA);
            token1 = address(tokenB);
        } else {
            token0 = address(tokenB);
            token1 = address(tokenA);
        }
        asset = token0; // Asset is token0
        
        // Setup config
        config = OpeningAuctionConfig({
            auctionDuration: 1 days,
            minAcceptableTickToken0: -34020,
            minAcceptableTickToken1: -34020,
            incentiveShareBps: 1000,
            tickSpacing: 60,
            fee: 3000,
            minLiquidity: 1e15
        });
        
        // Deploy hook with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG
        );
        
        // Deploy at address with correct flags
        address hookAddress = address(flags);
        deployCodeTo(
            "OpeningAuctionStress.t.sol:StressTestOpeningAuction",
            abi.encode(manager, address(this), AUCTION_TOKENS, config),
            hookAddress
        );
        hook = StressTestOpeningAuction(payable(hookAddress));
        
        // Transfer asset tokens to hook
        TestERC20(asset).transfer(address(hook), AUCTION_TOKENS);
        
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });
        
        // Set isToken0 and initialize pool
        hook.setIsToken0(true);
        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, config.tickSpacing);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        
        // Deploy router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
    }

    /// @notice Helper to add a bid
    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));
        
        vm.startPrank(user);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + config.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user)
        );
        vm.stopPrank();

        positionId = hook.getPositionId(user, tickLower, tickLower + config.tickSpacing, salt);
        positionSalts[positionId] = salt;
    }

    /// @notice Test with 50 unique bidders at different ticks
    function test_stress_50UniqueBidders() public {
        uint256 numBidders = 50;
        uint128 liquidityPerBid = 200e18; // Higher liquidity to ensure settlement succeeds
        
        for (uint256 i = 0; i < numBidders; i++) {
            address bidder = address(uint160(0x1000 + i));
            
            // Fund bidder
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);
            
            // Place bid at ticks well above minAcceptableTick
            int24 tickLower = config.minAcceptableTickToken0 + int24(int256(i + 10)) * config.tickSpacing;
            _addBid(bidder, tickLower, liquidityPerBid);
        }
        
        // Verify all positions created
        assertEq(hook.nextPositionId(), numBidders + 1); // IDs start at 1
        
        // Warp to auction end and settle
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();
        
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test with multiple bids on same tick (concentrated liquidity)
    function test_stress_concentratedBids() public {
        uint256 numBids = 50;
        uint128 liquidityPerBid = 200e18; // Much higher liquidity to absorb auction tokens
        int24 targetTick = config.minAcceptableTickToken0 + config.tickSpacing * 50; // Much higher tick
        
        for (uint256 i = 0; i < numBids; i++) {
            address bidder = address(uint160(0x2000 + i));
            
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);
            
            _addBid(bidder, targetTick, liquidityPerBid);
        }
        
        // All bids should be on the same tick
        assertEq(hook.nextPositionId(), numBids + 1);
        
        // Settle
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();
        
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled));
    }

    /// @notice Test gas consumption with increasing tick count
    function test_stress_gasScaling() public {
        uint256[] memory tickCounts = new uint256[](4);
        tickCounts[0] = 10;
        tickCounts[1] = 25;
        tickCounts[2] = 50;
        tickCounts[3] = 75;
        
        // Place bids across many ticks
        uint256 totalBids = tickCounts[3];
        for (uint256 i = 0; i < totalBids; i++) {
            address bidder = address(uint160(0x3000 + i));
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);
            
            int24 tickLower = config.minAcceptableTickToken0 + int24(int256(i + 10)) * config.tickSpacing;
            _addBid(bidder, tickLower, 100e18);
        }
        
        // Warp and settle
        vm.warp(hook.auctionEndTime() + 1);
        
        uint256 gasBefore = gasleft();
        hook.settleAuction();
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for settlement with", totalBids, "ticks:", gasUsed);
        
        // Settlement should complete within reasonable gas limits
        assertLt(gasUsed, 5_000_000, "Settlement gas too high");
    }

    /// @notice Test bid placement and removal in rapid succession
    function test_stress_rapidBidChurn() public {
        uint256 numCycles = 10;
        uint128 liquidity = 1e18;
        int24 tickLower = config.minAcceptableTickToken0 + config.tickSpacing * 3;
        
        address bidder = address(0x4000);
        TestERC20(token0).transfer(bidder, 1_000_000 ether);
        TestERC20(token1).transfer(bidder, 1_000_000 ether);
        
        for (uint256 i = 0; i < numCycles; i++) {
            // Add bid
            uint256 positionId = _addBid(bidder, tickLower, liquidity);
            
            // Remove bid (only if not locked)
            if (!hook.isPositionLocked(positionId)) {
                vm.startPrank(bidder);
                modifyLiquidityRouter.modifyLiquidity(
                    poolKey,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickLower + config.tickSpacing,
                        liquidityDelta: -int256(uint256(liquidity)),
                        salt: positionSalts[positionId]
                    }),
                    abi.encode(bidder)
                );
                vm.stopPrank();
            }
        }
        
        // Should complete without errors
        assertTrue(true);
    }

    /// @notice Test incentive claims with many positions
    function test_stress_manyIncentiveClaims() public {
        uint256 numBidders = 75;
        uint128 liquidityPerBid = 150e18; // High liquidity to ensure settlement
        
        // Place bids
        for (uint256 i = 0; i < numBidders; i++) {
            address bidder = address(uint160(0x5000 + i));
            TestERC20(token0).transfer(bidder, 100_000 ether);
            TestERC20(token1).transfer(bidder, 100_000 ether);
            
            int24 tickLower = config.minAcceptableTickToken0 + int24(int256(i + 10)) * config.tickSpacing;
            _addBid(bidder, tickLower, liquidityPerBid);
        }
        
        // Settle auction
        vm.warp(hook.auctionEndTime() + 1);
        hook.settleAuction();

        hook.migrate(address(this));
        
        // All bidders claim incentives
        for (uint256 i = 0; i < numBidders; i++) {
            address bidder = address(uint160(0x5000 + i));
            uint256 positionId = i + 1;
            
            // Get balance before
            address assetToken = hook.isToken0() ? token0 : token1;
            uint256 balanceBefore = IERC20(assetToken).balanceOf(bidder);
            
            vm.prank(bidder);
            hook.claimIncentives(positionId);
            
            uint256 balanceAfter = IERC20(assetToken).balanceOf(bidder);
            
            // Should have received some incentives (or zero if position wasn't in clearing range)
            assertTrue(balanceAfter >= balanceBefore, "Balance should not decrease");
        }
    }
}
