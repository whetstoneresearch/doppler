// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionImplementation is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}

    // Test helper getters for bitmap state
    function getHasActiveTicks() external view returns (bool) {
        return hasActiveTicks;
    }

    function getActiveTickCount() external view returns (uint256) {
        return activeTickCount;
    }

    function getMinActiveTick() external view returns (int24) {
        if (!hasActiveTicks) return 0;
        return _decompressTick(minActiveTick);
    }

    function getMaxActiveTick() external view returns (int24) {
        if (!hasActiveTicks) return 0;
        return _decompressTick(maxActiveTick);
    }

    function isTickActive(int24 tick) external view returns (bool) {
        return _isTickActive(tick);
    }
}

contract OpeningAuctionBaseTest is Test, Deployers {
    // Default config values - use smaller amounts for tests since liquidity provided is limited
    uint256 constant DEFAULT_AUCTION_TOKENS = 100 ether;  // 100 tokens (realistic for test liquidity)
    uint256 constant DEFAULT_AUCTION_DURATION = 1 days;
    int24 constant DEFAULT_MIN_ACCEPTABLE_TICK = -34_020; // ~0.033 price floor (e.g., 10k USD min raise at 3k ETH for 100 tokens)
    uint256 constant DEFAULT_INCENTIVE_SHARE_BPS = 1000; // 10%
    int24 constant DEFAULT_TICK_SPACING = 60;
    uint24 constant DEFAULT_FEE = 3000;
    uint128 constant DEFAULT_MIN_LIQUIDITY = 1e15; // Minimum liquidity to prevent dust griefing

    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    // Hook with proper flags
    OpeningAuctionImplementation hook;

    // Pool configuration
    address asset;
    address numeraire;
    address token0;
    address token1;
    PoolId poolId;
    bool isToken0;

    // Users
    address alice = address(0xa71c3);
    address bob = address(0xb0b);
    address initializer = address(0xbeef);
    uint256 bidNonce;

    /// @notice Get the hook flags for OpeningAuction
    function getHookFlags() internal pure returns (uint160) {
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

    /// @notice Deploy tokens
    function _deployTokens() public {
        isToken0 = true;

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = isToken0 ? TOKEN_A : TOKEN_B;
        numeraire = isToken0 ? TOKEN_B : TOKEN_A;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");
    }

    /// @notice Get default config
    function getDefaultConfig() public pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: DEFAULT_AUCTION_DURATION,
            minAcceptableTickToken0: DEFAULT_MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: DEFAULT_MIN_ACCEPTABLE_TICK,
            incentiveShareBps: DEFAULT_INCENTIVE_SHARE_BPS,
            tickSpacing: DEFAULT_TICK_SPACING,
            fee: DEFAULT_FEE,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });
    }

    /// @notice Deploy OpeningAuction hook with default config
    function _deployOpeningAuction() public {
        _deployOpeningAuction(getDefaultConfig(), DEFAULT_AUCTION_TOKENS);
    }

    /// @notice Deploy OpeningAuction hook with custom config
    function _deployOpeningAuction(OpeningAuctionConfig memory config, uint256 auctionTokens) public {
        // Calculate hook address with proper flags
        address hookAddress = address(uint160(getHookFlags()) ^ (0x4444 << 144));

        // Deploy hook implementation to the calculated address
        deployCodeTo(
            "OpeningAuctionBaseTest.sol:OpeningAuctionImplementation",
            abi.encode(manager, initializer, auctionTokens, config),
            hookAddress
        );

        hook = OpeningAuctionImplementation(payable(hookAddress));
        vm.label(address(hook), "OpeningAuction");

        // Transfer tokens to hook
        TestERC20(asset).transfer(address(hook), auctionTokens);

        // Create pool key
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        poolId = key.toId();

        // Set isToken0 on hook
        vm.prank(initializer);
        hook.setIsToken0(isToken0);

        // Initialize pool at extreme price boundary
        int24 startingTick = alignTickTowardZero(
            isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK,
            config.tickSpacing
        );

        vm.prank(initializer);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(startingTick));
    }

    function setUp() public virtual {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        _deployTokens();

        // Deploy opening auction
        _deployOpeningAuction();

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        // Approve routers
        TestERC20(token0).approve(address(swapRouter), type(uint256).max);
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(swapRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Fund users
        TestERC20(token0).transfer(alice, 1_000_000 ether);
        TestERC20(token1).transfer(alice, 1_000_000 ether);
        TestERC20(token0).transfer(bob, 1_000_000 ether);
        TestERC20(token1).transfer(bob, 1_000_000 ether);
    }

    /// @notice Helper to add a bid (liquidity position) using the router with hookData
    /// @param user The user placing the bid
    /// @param tickLower The lower tick for the position
    /// @param liquidity The liquidity amount to add
    /// @return positionId The ID of the created position
    function _addBid(address user, int24 tickLower, uint128 liquidity) internal returns (uint256 positionId) {
        int24 tickUpper = tickLower + key.tickSpacing;
        bytes32 salt = keccak256(abi.encode(user, bidNonce++));

        vm.startPrank(user);
        // Approve the router to spend tokens
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity through router, passing owner in hookData
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encode(user) // Pass owner in hookData
        );
        vm.stopPrank();

        positionId = hook.getPositionId(user, tickLower, tickUpper, salt);
    }

    /// @notice Helper to warp to auction end
    function _warpToAuctionEnd() internal {
        vm.warp(hook.auctionEndTime() + 1);
    }
}
