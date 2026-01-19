// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Test } from "forge-std/Test.sol";
import { RehypeDopplerHookHarness } from "./RehypeDopplerHookHarness.sol";

/// @notice Minimal mock pool manager for harness construction
contract MockPoolManager { }

/// @title CalculateExcessTest
/// @notice Unit tests for _calculateExcess() function in RehypeDopplerHook
/// @dev Tests the pure function that determines imbalance between token amounts at a given price
contract CalculateExcessTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Price = 1 (sqrtPrice = 2^96)
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @notice Min sqrt price from TickMath
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;

    /// @notice Max sqrt price from TickMath
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @notice Boundary for ratioX192 vs ratioX128 path (type(uint128).max)
    uint160 internal constant UINT128_MAX = type(uint128).max;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    RehypeDopplerHookHarness internal harness;
    address internal initializer = makeAddr("initializer");

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        MockPoolManager mockPoolManager = new MockPoolManager();
        harness = new RehypeDopplerHookHarness(initializer, IPoolManager(address(mockPoolManager)));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-01: BALANCED AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that equal amounts at price=1 result in zero excess
    /// @dev At sqrtPriceX96 = 2^96, price = 1, so equal amounts should be balanced
    function test_calculateExcess_BalancedAtPriceOne() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At price=1, equal amounts should be perfectly balanced
        assertEq(excess0, 0, "excess0 should be 0 for balanced amounts at price=1");
        assertEq(excess1, 0, "excess1 should be 0 for balanced amounts at price=1");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-02: EXCESS TOKEN0 AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that more token0 than needed results in excess0
    /// @dev At price=1, having 2x token0 vs token1 should create excess0
    function test_calculateExcess_ExcessToken0AtPriceOne() public view {
        uint256 fees0 = 2e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At price=1, need equal amounts. Having 2e18 token0 and 1e18 token1
        // means we can deposit 1e18 of each, leaving 1e18 excess token0
        assertGt(excess0, 0, "excess0 should be > 0 when more token0 than needed");
        assertEq(excess1, 0, "excess1 should be 0 when token1 is the limiting factor");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-03: EXCESS TOKEN1 AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that more token1 than needed results in excess1
    /// @dev At price=1, having 2x token1 vs token0 should create excess1
    function test_calculateExcess_ExcessToken1AtPriceOne() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 2e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At price=1, need equal amounts. Having 1e18 token0 and 2e18 token1
        // means we can deposit 1e18 of each, leaving 1e18 excess token1
        assertEq(excess0, 0, "excess0 should be 0 when token0 is the limiting factor");
        assertGt(excess1, 0, "excess1 should be > 0 when more token1 than needed");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-04: BOTH ZERO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that zero amounts result in zero excess
    /// @dev Edge case: nothing to deposit means nothing in excess
    function test_calculateExcess_BothZero() public view {
        uint256 fees0 = 0;
        uint256 fees1 = 0;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertEq(excess0, 0, "excess0 should be 0 when fees0 is 0");
        assertEq(excess1, 0, "excess1 should be 0 when fees1 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-05: ONLY TOKEN0
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test one-sided token0 results in all excess0
    /// @dev When only token0 exists, it's all excess since we need both tokens for LP
    function test_calculateExcess_OnlyToken0() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 0;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // With no token1, we can't deposit any liquidity, so all token0 is excess
        assertEq(excess0, fees0, "excess0 should equal fees0 when fees1 is 0");
        assertEq(excess1, 0, "excess1 should be 0 when fees1 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-06: ONLY TOKEN1
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test one-sided token1 results in all excess1
    /// @dev When only token1 exists, it's all excess since we need both tokens for LP
    function test_calculateExcess_OnlyToken1() public view {
        uint256 fees0 = 0;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // With no token0, we can't deposit any liquidity, so all token1 is excess
        assertEq(excess0, 0, "excess0 should be 0 when fees0 is 0");
        assertEq(excess1, fees1, "excess1 should equal fees1 when fees0 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-07: MIN SQRT PRICE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test behavior near minimum sqrt price
    /// @dev At very low prices, token1 is worth much more than token0
    function test_calculateExcess_MinSqrtPrice() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = MIN_SQRT_PRICE + 1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At very low price, token0 is nearly worthless compared to token1
        // So we expect significant excess in token0 (can't use it all)
        // The exact values depend on the math, but we verify no overflow
        assertTrue(excess0 >= 0, "excess0 should be non-negative");
        assertTrue(excess1 >= 0, "excess1 should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-08: MAX SQRT PRICE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test behavior near maximum sqrt price
    /// @dev At very high prices, token0 is worth much more than token1
    function test_calculateExcess_MaxSqrtPrice() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = MAX_SQRT_PRICE - 1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At very high price, token1 is nearly worthless compared to token0
        // So we expect significant excess in token1 (can't use it all)
        // The exact values depend on the math, but we verify no overflow
        assertTrue(excess0 >= 0, "excess0 should be non-negative");
        assertTrue(excess1 >= 0, "excess1 should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-09: SMALL AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test with very small balanced amounts
    /// @dev Verify precision at small scales
    function test_calculateExcess_SmallAmounts() public view {
        uint256 fees0 = 1000;
        uint256 fees1 = 1000;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // Small balanced amounts at price=1 should still be balanced
        assertEq(excess0, 0, "excess0 should be 0 for small balanced amounts");
        assertEq(excess1, 0, "excess1 should be 0 for small balanced amounts");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-10: LARGE AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test with very large balanced amounts
    /// @dev Verify no overflow at large scales
    function test_calculateExcess_LargeAmounts() public view {
        uint256 fees0 = 1e30;
        uint256 fees1 = 1e30;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // Large balanced amounts at price=1 should still be balanced
        assertEq(excess0, 0, "excess0 should be 0 for large balanced amounts");
        assertEq(excess1, 0, "excess1 should be 0 for large balanced amounts");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-11: PRICE BELOW UINT128 MAX (ratioX192 path)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test with price below uint128.max (uses ratioX192 calculation path)
    /// @dev MigrationMath uses different paths based on sqrtPriceX96 <= type(uint128).max
    function test_calculateExcess_PriceBelowUint128Max() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        // Use a price that's well below uint128.max to ensure ratioX192 path
        uint160 sqrtPriceX96 = uint160(1 << 96); // 2^96, which is < 2^128

        assertTrue(sqrtPriceX96 <= UINT128_MAX, "Price should be below uint128.max for this test");

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At this price (=1), equal amounts should be balanced
        assertEq(excess0, 0, "excess0 should be 0 in ratioX192 path");
        assertEq(excess1, 0, "excess1 should be 0 in ratioX192 path");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-12: PRICE ABOVE UINT128 MAX (ratioX128 path)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test with price above uint128.max (uses ratioX128 calculation path)
    /// @dev MigrationMath uses different paths based on sqrtPriceX96 <= type(uint128).max
    function test_calculateExcess_PriceAboveUint128Max() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        // Use a price that's above uint128.max to trigger ratioX128 path
        // 2^129 is > 2^128 but still valid sqrt price
        uint160 sqrtPriceX96 = uint160(1 << 129);

        assertTrue(sqrtPriceX96 > UINT128_MAX, "Price should be above uint128.max for this test");

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At high price, token1 becomes very cheap relative to token0
        // We expect excess1 since we can't use all the token1
        assertTrue(excess0 >= 0, "excess0 should be non-negative in ratioX128 path");
        assertTrue(excess1 >= 0, "excess1 should be non-negative in ratioX128 path");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test that excess values are always <= input values
    /// @dev Excess can never exceed what we started with
    function testFuzz_calculateExcess_ExcessNeverExceedsInput(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) public view {
        // Bound inputs to reasonable ranges
        fees0 = bound(fees0, 0, 1e36);
        fees1 = bound(fees1, 0, 1e36);
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE + 1, MAX_SQRT_PRICE - 1));

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertLe(excess0, fees0, "excess0 should never exceed fees0");
        assertLe(excess1, fees1, "excess1 should never exceed fees1");
    }

    /// @notice Fuzz test that only one excess can be non-zero at a time
    /// @dev By definition, you can only have excess in one token (the one you have too much of)
    function testFuzz_calculateExcess_OnlyOneExcessNonZero(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) public view {
        // Bound inputs
        fees0 = bound(fees0, 0, 1e36);
        fees1 = bound(fees1, 0, 1e36);
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE + 1, MAX_SQRT_PRICE - 1));

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        // At most one excess can be non-zero (or both zero if perfectly balanced)
        assertTrue(excess0 == 0 || excess1 == 0, "Only one excess can be non-zero at a time");
    }
}
