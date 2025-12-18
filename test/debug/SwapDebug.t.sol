// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";

/// @notice Debug test to understand V4 swap delta conventions
contract SwapDebugTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant TOKEN_A = address(0x1111);
    address constant TOKEN_B = address(0x2222);

    function setUp() public {
        manager = new PoolManager(address(this));

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        TestERC20(TOKEN_A).approve(address(swapRouter), type(uint256).max);
        TestERC20(TOKEN_B).approve(address(swapRouter), type(uint256).max);
        TestERC20(TOKEN_A).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(TOKEN_B).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_swapDeltaConventions() public {
        // Create a simple pool without hooks
        (address token0, address token1) = TOKEN_A < TOKEN_B ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Initialize at tick 0 (1:1 price)
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        // Add some liquidity around tick 0
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10000e18,
                salt: bytes32(0)
            }),
            ""
        );

        console2.log("=== Initial State ===");
        console2.log("Token0:", token0);
        console2.log("Token1:", token1);

        uint256 balBefore0 = TestERC20(token0).balanceOf(address(this));
        uint256 balBefore1 = TestERC20(token1).balanceOf(address(this));

        console2.log("Balance token0 before:", balBefore0);
        console2.log("Balance token1 before:", balBefore1);

        // Execute a zeroForOne swap (sell token0 for token1)
        console2.log("\n=== Executing zeroForOne swap (SELL token0) ===");
        console2.log("amountSpecified: -1000 (exact input of 1000 token0)");

        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1000, // negative = exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        console2.log("\n=== Swap Result ===");
        console2.log("delta.amount0():", delta.amount0());
        console2.log("delta.amount1():", delta.amount1());

        uint256 balAfter0 = TestERC20(token0).balanceOf(address(this));
        uint256 balAfter1 = TestERC20(token1).balanceOf(address(this));

        console2.log("\n=== Balance Changes ===");
        console2.log("Balance token0 after:", balAfter0);
        console2.log("Balance token1 after:", balAfter1);
        console2.log("Token0 change:", int256(balAfter0) - int256(balBefore0));
        console2.log("Token1 change:", int256(balAfter1) - int256(balBefore1));

        // Verify expectations
        // For selling token0:
        // - We should have LESS token0 (paid it)
        // - We should have MORE token1 (received it)
        assertLt(balAfter0, balBefore0, "Should have less token0 after selling");
        assertGt(balAfter1, balBefore1, "Should have more token1 after selling");

        console2.log("\n=== Interpretation ===");
        if (delta.amount0() > 0) {
            console2.log("delta.amount0() > 0: Caller OWES pool token0 (correct for sell)");
        } else {
            console2.log("delta.amount0() < 0: Pool OWES caller token0 (unexpected for sell!)");
        }
        if (delta.amount1() < 0) {
            console2.log("delta.amount1() < 0: Pool OWES caller token1 (correct for sell)");
        } else {
            console2.log("delta.amount1() > 0: Caller OWES pool token1 (unexpected for sell!)");
        }
    }

    function test_swapAtMaxTick() public {
        // Simulate the auction scenario: pool at MAX_TICK, liquidity at lower ticks
        (address token0, address token1) = TOKEN_A < TOKEN_B ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Initialize at MAX_TICK (like the auction)
        int24 maxTick = TickMath.MAX_TICK - (TickMath.MAX_TICK % 60);
        console2.log("=== Initializing at MAX_TICK ===");
        console2.log("maxTick:", maxTick);

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(maxTick));

        // Add liquidity at a lower tick (like auction bids)
        int24 tickLower = -99960;
        int24 tickUpper = tickLower + 60;

        console2.log("\n=== Adding liquidity at low tick ===");
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );

        uint256 balBefore0 = TestERC20(token0).balanceOf(address(this));
        uint256 balBefore1 = TestERC20(token1).balanceOf(address(this));

        console2.log("\n=== Executing zeroForOne swap from MAX_TICK ===");
        console2.log("Trying to sell token0...");

        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1000000e18, // Try to sell a lot
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        console2.log("\n=== Swap Result ===");
        console2.log("delta.amount0():", delta.amount0());
        console2.log("delta.amount1():", delta.amount1());

        uint256 balAfter0 = TestERC20(token0).balanceOf(address(this));
        uint256 balAfter1 = TestERC20(token1).balanceOf(address(this));

        console2.log("\n=== Balance Changes ===");
        console2.log("Token0 change:", int256(balAfter0) - int256(balBefore0));
        console2.log("Token1 change:", int256(balAfter1) - int256(balBefore1));

        // Check final pool state
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(poolKey.toId());
        console2.log("\n=== Final Pool State ===");
        console2.log("Final tick:", tick);
        console2.log("Final sqrtPrice:", sqrtPrice);
    }
}
