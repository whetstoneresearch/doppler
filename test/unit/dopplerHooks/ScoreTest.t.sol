// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Test } from "forge-std/Test.sol";
import { RehypeDopplerHookHarness } from "./RehypeDopplerHookHarness.sol";

/// @notice Minimal mock pool manager for harness construction
contract MockPoolManager { }

/// @title ScoreTest
/// @notice Unit tests for _score() function in RehypeDopplerHook
/// @dev Tests the pure function that returns max(excess0, excess1)
contract ScoreTest is Test {
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
    // SC-01: FIRST GREATER
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that first value is returned when it's greater
    /// @dev _score returns max(excess0, excess1)
    function test_score_FirstGreater() public view {
        uint256 result = harness.exposed_score(100, 50);
        assertEq(result, 100, "Should return the greater value (first)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-02: SECOND GREATER
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that second value is returned when it's greater
    /// @dev _score returns max(excess0, excess1)
    function test_score_SecondGreater() public view {
        uint256 result = harness.exposed_score(50, 100);
        assertEq(result, 100, "Should return the greater value (second)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-03: EQUAL
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that either value is returned when they're equal
    /// @dev _score returns max(excess0, excess1), which is the same when equal
    function test_score_Equal() public view {
        uint256 result = harness.exposed_score(100, 100);
        assertEq(result, 100, "Should return the value when both are equal");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-04: BOTH ZERO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that zero is returned when both values are zero
    /// @dev Edge case: max(0, 0) = 0
    function test_score_BothZero() public view {
        uint256 result = harness.exposed_score(0, 0);
        assertEq(result, 0, "Should return 0 when both values are 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-05: FIRST ZERO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that second value is returned when first is zero
    /// @dev max(0, X) = X
    function test_score_FirstZero() public view {
        uint256 result = harness.exposed_score(0, 100);
        assertEq(result, 100, "Should return second value when first is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-06: SECOND ZERO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test that first value is returned when second is zero
    /// @dev max(X, 0) = X
    function test_score_SecondZero() public view {
        uint256 result = harness.exposed_score(100, 0);
        assertEq(result, 100, "Should return first value when second is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SC-07: MAX VALUES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test with maximum uint256 values
    /// @dev Boundary test for max values
    function test_score_MaxValues() public view {
        uint256 result = harness.exposed_score(type(uint256).max, type(uint256).max - 1);
        assertEq(result, type(uint256).max, "Should return type(uint256).max");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test that _score always returns the maximum of the two inputs
    function testFuzz_score_ReturnsMax(uint256 excess0, uint256 excess1) public view {
        uint256 result = harness.exposed_score(excess0, excess1);

        uint256 expected = excess0 > excess1 ? excess0 : excess1;
        assertEq(result, expected, "Should return max(excess0, excess1)");
    }

    /// @notice Fuzz test that _score is commutative when values are equal
    /// @dev When excess0 == excess1, order shouldn't matter
    function testFuzz_score_CommutativeWhenEqual(uint256 value) public view {
        uint256 result1 = harness.exposed_score(value, value);
        uint256 result2 = harness.exposed_score(value, value);

        assertEq(result1, result2, "Score should be same regardless of order when equal");
        assertEq(result1, value, "Score should equal the value when both inputs are same");
    }

    /// @notice Fuzz test that result is always >= both inputs
    function testFuzz_score_ResultGreaterOrEqual(uint256 excess0, uint256 excess1) public view {
        uint256 result = harness.exposed_score(excess0, excess1);

        assertGe(result, excess0, "Result should be >= excess0");
        assertGe(result, excess1, "Result should be >= excess1");
    }
}
