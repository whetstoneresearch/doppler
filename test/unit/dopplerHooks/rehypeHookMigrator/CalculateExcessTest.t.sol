// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { RehypeDopplerHookMigratorHarness } from "./RehypeDopplerHookMigratorHarness.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Test } from "forge-std/Test.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";

/// @notice Minimal mock pool manager for harness construction
contract MockPoolManager { }

/// @notice Minimal mock migrator for harness construction
contract MockMigrator {
    receive() external payable { }
}

/// @title CalculateExcessTest (Migrator)
/// @notice Unit tests for _calculateExcess() function in RehypeDopplerHookMigrator
/// @dev Tests the pure function that determines imbalance between token amounts at a given price
contract CalculateExcessMigratorTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Price = 1 (sqrtPrice = 2^96)
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    /// @notice Min sqrt price from TickMath
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;

    /// @notice Max sqrt price from TickMath
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice Boundary for ratioX192 vs ratioX128 path (type(uint128).max)
    uint160 internal constant UINT128_MAX = type(uint128).max;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    RehypeDopplerHookMigratorHarness internal harness;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        MockPoolManager mockPoolManager = new MockPoolManager();
        MockMigrator mockMigrator = new MockMigrator();
        harness = new RehypeDopplerHookMigratorHarness(
            DopplerHookMigrator(payable(address(mockMigrator))),
            IPoolManager(address(mockPoolManager))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-01: BALANCED AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_BalancedAtPriceOne() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertEq(excess0, 0, "excess0 should be 0 for balanced amounts at price=1");
        assertEq(excess1, 0, "excess1 should be 0 for balanced amounts at price=1");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-02: EXCESS TOKEN0 AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_ExcessToken0AtPriceOne() public view {
        uint256 fees0 = 2e18;
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertGt(excess0, 0, "excess0 should be > 0 when more token0 than needed");
        assertEq(excess1, 0, "excess1 should be 0 when token1 is the limiting factor");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-03: EXCESS TOKEN1 AT PRICE ONE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_ExcessToken1AtPriceOne() public view {
        uint256 fees0 = 1e18;
        uint256 fees1 = 2e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertEq(excess0, 0, "excess0 should be 0 when token0 is the limiting factor");
        assertGt(excess1, 0, "excess1 should be > 0 when more token1 than needed");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-04: BOTH ZERO
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_BothZero() public view {
        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(0, 0, SQRT_PRICE_1_1);

        assertEq(excess0, 0, "excess0 should be 0 when fees0 is 0");
        assertEq(excess1, 0, "excess1 should be 0 when fees1 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-05: ONLY TOKEN0
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_OnlyToken0() public view {
        uint256 fees0 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, 0, sqrtPriceX96);

        assertEq(excess0, fees0, "excess0 should equal fees0 when fees1 is 0");
        assertEq(excess1, 0, "excess1 should be 0 when fees1 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-06: ONLY TOKEN1
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_OnlyToken1() public view {
        uint256 fees1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(0, fees1, sqrtPriceX96);

        assertEq(excess0, 0, "excess0 should be 0 when fees0 is 0");
        assertEq(excess1, fees1, "excess1 should equal fees1 when fees0 is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-07: MIN SQRT PRICE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_MinSqrtPrice() public view {
        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1e18, 1e18, MIN_SQRT_PRICE + 1);

        assertTrue(excess0 >= 0, "excess0 should be non-negative");
        assertTrue(excess1 >= 0, "excess1 should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-08: MAX SQRT PRICE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_MaxSqrtPrice() public view {
        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1e18, 1e18, MAX_SQRT_PRICE - 1);

        assertTrue(excess0 >= 0, "excess0 should be non-negative");
        assertTrue(excess1 >= 0, "excess1 should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-09: SMALL AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_SmallAmounts() public view {
        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1000, 1000, SQRT_PRICE_1_1);

        assertEq(excess0, 0, "excess0 should be 0 for small balanced amounts");
        assertEq(excess1, 0, "excess1 should be 0 for small balanced amounts");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-10: LARGE AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_LargeAmounts() public view {
        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1e30, 1e30, SQRT_PRICE_1_1);

        assertEq(excess0, 0, "excess0 should be 0 for large balanced amounts");
        assertEq(excess1, 0, "excess1 should be 0 for large balanced amounts");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-11: PRICE BELOW UINT128 MAX (ratioX192 path)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_PriceBelowUint128Max() public view {
        uint160 sqrtPriceX96 = uint160(1 << 96);
        assertTrue(sqrtPriceX96 <= UINT128_MAX, "Price should be below uint128.max for this test");

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1e18, 1e18, sqrtPriceX96);

        assertEq(excess0, 0, "excess0 should be 0 in ratioX192 path");
        assertEq(excess1, 0, "excess1 should be 0 in ratioX192 path");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CE-12: PRICE ABOVE UINT128 MAX (ratioX128 path)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_calculateExcess_PriceAboveUint128Max() public view {
        uint160 sqrtPriceX96 = uint160(1 << 129);
        assertTrue(sqrtPriceX96 > UINT128_MAX, "Price should be above uint128.max for this test");

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(1e18, 1e18, sqrtPriceX96);

        assertTrue(excess0 >= 0, "excess0 should be non-negative in ratioX128 path");
        assertTrue(excess1 >= 0, "excess1 should be non-negative in ratioX128 path");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function testFuzz_calculateExcess_ExcessNeverExceedsInput(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) public view {
        fees0 = bound(fees0, 0, 1e36);
        fees1 = bound(fees1, 0, 1e36);
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE + 1, MAX_SQRT_PRICE - 1));

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertLe(excess0, fees0, "excess0 should never exceed fees0");
        assertLe(excess1, fees1, "excess1 should never exceed fees1");
    }

    function testFuzz_calculateExcess_OnlyOneExcessNonZero(
        uint256 fees0,
        uint256 fees1,
        uint160 sqrtPriceX96
    ) public view {
        fees0 = bound(fees0, 0, 1e36);
        fees1 = bound(fees1, 0, 1e36);
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE + 1, MAX_SQRT_PRICE - 1));

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(fees0, fees1, sqrtPriceX96);

        assertTrue(excess0 == 0 || excess1 == 0, "Only one excess can be non-zero at a time");
    }
}
