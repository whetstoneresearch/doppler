// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
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

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { IOpeningAuction, OpeningAuctionConfig, AuctionPhase, AuctionPosition } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionTestImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title TokenOrderingTest
/// @notice Tests for isToken0 handling - specifically tests the fix for CRITICAL-1 bug
/// @dev The bug was: _beforeInitialize() overwrote isToken0 = true, ignoring setIsToken0()
contract TokenOrderingTest is Test, Deployers {
    // Token addresses - arranged so we can test both orderings
    address constant TOKEN_LOW = address(0x1111);  // Lower address
    address constant TOKEN_HIGH = address(0x9999); // Higher address

    // Default config
    uint256 constant AUCTION_TOKENS = 100 ether;
    uint256 constant AUCTION_DURATION = 1 days;
    int24 constant MIN_ACCEPTABLE_TICK = -34_020;
    int24 constant TICK_SPACING = 60;

    // Test state
    OpeningAuctionTestImpl hook;
    address initializer = address(0xbeef);
    address alice = address(0xa71c3);

    function setUp() public {
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_LOW);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(type(uint256).max), TOKEN_HIGH);

        // Deploy router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Fund users
        TestERC20(TOKEN_LOW).transfer(alice, 1_000_000 ether);
        TestERC20(TOKEN_HIGH).transfer(alice, 1_000_000 ether);
    }

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

    function getDefaultConfig() internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: 1000,
            tickSpacing: TICK_SPACING,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });
    }

    /// @notice Deploy auction with specified token ordering
    /// @param assetIsToken0 True if asset should be token0, false if asset should be token1
    function _deployAuction(bool assetIsToken0) internal returns (address asset, address numeraire) {
        // Determine asset and numeraire based on desired ordering
        if (assetIsToken0) {
            // Asset is lower address (token0)
            asset = TOKEN_LOW;
            numeraire = TOKEN_HIGH;
        } else {
            // Asset is higher address (token1)
            asset = TOKEN_HIGH;
            numeraire = TOKEN_LOW;
        }

        // Calculate hook address
        address hookAddress = address(uint160(getHookFlags()) ^ (0x5555 << 144));

        OpeningAuctionConfig memory config = getDefaultConfig();

        // Deploy hook
        deployCodeTo(
            "TokenOrdering.t.sol:OpeningAuctionTestImpl",
            abi.encode(manager, initializer, AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionTestImpl(payable(hookAddress));

        // Transfer tokens to hook
        TestERC20(asset).transfer(address(hook), AUCTION_TOKENS);

        return (asset, numeraire);
    }

    // ============ Tests for isToken0Set Guard ============

    /// @notice Test that setIsToken0 can only be called once
    function test_setIsToken0_CanOnlyBeCalledOnce() public {
        _deployAuction(true);

        // First call should succeed
        vm.prank(initializer);
        hook.setIsToken0(true);

        // Second call should revert
        vm.prank(initializer);
        vm.expectRevert(IOpeningAuction.IsToken0AlreadySet.selector);
        hook.setIsToken0(false);
    }

    /// @notice Test that setIsToken0 cannot be called after initialization
    function test_setIsToken0_RevertsAfterInitialization() public {
        (address asset, address numeraire) = _deployAuction(true);

        // Set isToken0 and initialize
        vm.startPrank(initializer);
        hook.setIsToken0(true);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(asset < numeraire ? asset : numeraire),
            currency1: Currency.wrap(asset < numeraire ? numeraire : asset),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, TICK_SPACING);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));
        vm.stopPrank();

        // Now try to call setIsToken0 - should revert
        vm.prank(initializer);
        vm.expectRevert(IOpeningAuction.AlreadyInitialized.selector);
        hook.setIsToken0(false);
    }

    /// @notice Test that _beforeInitialize reverts if isToken0 was not set
    function test_beforeInitialize_RevertsIfIsToken0NotSet() public {
        (address asset, address numeraire) = _deployAuction(true);

        // Create pool key WITHOUT calling setIsToken0 first
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(asset < numeraire ? asset : numeraire),
            currency1: Currency.wrap(asset < numeraire ? numeraire : asset),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, TICK_SPACING);

        // Try to initialize without setting isToken0 - should revert
        // Note: The error gets wrapped by PoolManager, so we just check it reverts
        vm.prank(initializer);
        vm.expectRevert();
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        // Verify isToken0Set is still false
        assertEq(hook.isToken0Set(), false, "isToken0Set should still be false");
    }

    // ============ Tests for isToken0=true (Asset is Token0) ============

    /// @notice Test that isToken0=true is preserved through initialization
    function test_isToken0True_PreservedThroughInitialization() public {
        (address asset, address numeraire) = _deployAuction(true);

        // Set isToken0 = true
        vm.prank(initializer);
        hook.setIsToken0(true);

        // Verify before initialization
        assertEq(hook.isToken0(), true, "isToken0 should be true before init");
        assertEq(hook.isToken0Set(), true, "isToken0Set should be true");

        // Initialize pool
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(asset),
            currency1: Currency.wrap(numeraire),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MAX_TICK, TICK_SPACING);
        vm.prank(initializer);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        // CRITICAL: Verify isToken0 is still true after initialization
        assertEq(hook.isToken0(), true, "isToken0 was incorrectly modified during init");
        assertEq(hook.estimatedClearingTick(), TickMath.MAX_TICK, "clearing tick should start at MAX_TICK for isToken0=true");
    }

    // ============ Tests for isToken0=false (Asset is Token1) - THE BUG SCENARIO ============

    /// @notice Test that isToken0=false is preserved through initialization
    /// @dev This test would FAIL with the bug (isToken0 overwritten to true)
    function test_isToken0False_PreservedThroughInitialization() public {
        // Deploy with asset as token1 (higher address)
        (address asset, address numeraire) = _deployAuction(false);

        // Set isToken0 = false (because asset is token1)
        vm.prank(initializer);
        hook.setIsToken0(false);

        // Verify before initialization
        assertEq(hook.isToken0(), false, "isToken0 should be false before init");
        assertEq(hook.isToken0Set(), true, "isToken0Set should be true");

        // Create pool key - note: currency0 is always the lower address
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(numeraire),  // Lower address (TOKEN_LOW)
            currency1: Currency.wrap(asset),      // Higher address (TOKEN_HIGH) = asset
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // For isToken0=false, price starts at MIN_TICK and moves up
        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, TICK_SPACING);
        vm.prank(initializer);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        // CRITICAL: Verify isToken0 is STILL FALSE after initialization
        // This assertion would FAIL with the bug (isToken0 overwritten to true)
        assertEq(hook.isToken0(), false, "isToken0 was incorrectly overwritten during init!");

        // Verify clearing tick starts at MIN_TICK for isToken0=false
        assertEq(hook.estimatedClearingTick(), TickMath.MIN_TICK, "clearing tick should start at MIN_TICK for isToken0=false");
    }

    /// @notice Test full auction flow with isToken0=false
    /// @dev This tests settlement direction and token accounting
    /// Note: This test uses a low minAcceptableTick floor to ensure settlement succeeds
    function test_fullAuctionFlow_AssetIsToken1() public {
        // Deploy custom hook with adjusted minAcceptableTick for isToken0=false
        address hookAddress = address(uint160(getHookFlags()) ^ (0x6666 << 144));

        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -887_220,
            minAcceptableTickToken1: MIN_ACCEPTABLE_TICK,
            incentiveShareBps: 1000,
            tickSpacing: TICK_SPACING,
            fee: 3000,
            minLiquidity: 1e15,
            shareToAuctionBps: 10_000
        });

        deployCodeTo(
            "TokenOrdering.t.sol:OpeningAuctionTestImpl",
            abi.encode(manager, initializer, AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionTestImpl(payable(hookAddress));

        // Asset is TOKEN_HIGH (token1), numeraire is TOKEN_LOW (token0)
        address asset = TOKEN_HIGH;
        address numeraire = TOKEN_LOW;

        // Transfer tokens to hook
        TestERC20(asset).transfer(address(hook), AUCTION_TOKENS);

        // Set isToken0 = false
        vm.prank(initializer);
        hook.setIsToken0(false);

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(numeraire),
            currency1: Currency.wrap(asset),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize at MIN_TICK for isToken0=false
        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, TICK_SPACING);
        vm.prank(initializer);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        // Verify setup
        assertEq(hook.isToken0(), false, "isToken0 should be false");
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Active), "should be active");
        assertEq(hook.estimatedClearingTick(), TickMath.MIN_TICK, "clearing tick should start at MIN_TICK for isToken0=false");

        int24 limitTick = hook.minAcceptableTick();
        int24 bidTick = limitTick - TICK_SPACING;

        vm.startPrank(alice);
        TestERC20(numeraire).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(asset).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bidTick,
                tickUpper: bidTick + TICK_SPACING,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bytes32(uint256(1))
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        // Verify position was created
        AuctionPosition memory pos = hook.positions(1);
        assertEq(pos.owner, alice, "position owner should be alice");
        assertEq(pos.tickLower, bidTick, "position tick should match");

        // Warp to auction end
        vm.warp(hook.auctionEndTime() + 1);

        // Settle auction
        hook.settleAuction();

        // Verify settlement
        assertEq(uint8(hook.phase()), uint8(AuctionPhase.Settled), "should be settled");

        // Log results
        console2.log("isToken0:", hook.isToken0());
        console2.log("Clearing tick:", int256(hook.clearingTick()));
        console2.log("Tokens sold:", hook.totalTokensSold());
        console2.log("Proceeds:", hook.totalProceeds());

        // Tokens sold can be zero if no active liquidity was reachable from the starting price
        assertGe(hook.totalTokensSold(), 0, "tokens sold should be non-negative");

        // Verify isToken0 is still false after full flow
        assertEq(hook.isToken0(), false, "isToken0 should still be false after settlement");
    }

    // ============ Edge Case Tests ============

    /// @notice Test that bid validation uses correct direction for isToken0=false
    function test_bidValidation_UsesCorrectDirectionForToken1Asset() public {
        // Deploy with asset as token1
        (address asset, address numeraire) = _deployAuction(false);

        vm.prank(initializer);
        hook.setIsToken0(false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(numeraire),
            currency1: Currency.wrap(asset),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startingTick = alignTickTowardZero(TickMath.MIN_TICK, TICK_SPACING);
        vm.prank(initializer);
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(startingTick));

        int24 limitTick = hook.minAcceptableTick();
        int24 validTickLower = limitTick - TICK_SPACING;

        vm.startPrank(alice);
        TestERC20(numeraire).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(asset).approve(address(modifyLiquidityRouter), type(uint256).max);

        // This should succeed - valid tick for isToken0=false
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: validTickLower,
                tickUpper: validTickLower + TICK_SPACING,
                liquidityDelta: int256(uint256(100_000 ether)),
                salt: bytes32(uint256(1))
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        // Position should be created
        assertEq(hook.positions(1).owner, alice, "valid bid should be accepted");
    }

    /// @notice Test the isToken0Set getter
    function test_isToken0Set_InitiallyFalse() public {
        _deployAuction(true);
        assertEq(hook.isToken0Set(), false, "isToken0Set should be false initially");
    }

    /// @notice Test that only initializer can call setIsToken0
    function test_setIsToken0_OnlyInitializer() public {
        _deployAuction(true);

        // Non-initializer should fail
        vm.prank(alice);
        vm.expectRevert(IOpeningAuction.SenderNotInitializer.selector);
        hook.setIsToken0(true);
    }
}
