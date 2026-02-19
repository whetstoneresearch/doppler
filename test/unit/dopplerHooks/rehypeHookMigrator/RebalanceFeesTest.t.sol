// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { RehypeDopplerHookMigratorHarness } from "./RehypeDopplerHookMigratorHarness.sol";
import { Quoter } from "@quoter/Quoter.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { EPSILON } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { MockQuoter } from "test/unit/dopplerHooks/rehypeHook/MockQuoter.sol";

/// @notice Minimal mock pool manager for harness construction
contract MockPoolManager { }

/// @notice Minimal mock migrator for harness construction
contract MockMigrator {
    receive() external payable { }
}

/// @title RebalanceFeesTest (Migrator)
/// @notice Unit tests for _rebalanceFees() function in RehypeDopplerHookMigrator
/// @dev Tests the binary search algorithm for optimal LP rebalancing
/// @dev Note: The migrator version has `if (high == 1)` instead of `if (high == 0 || high == 1)`
contract RebalanceFeesMigratorTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint128 internal constant TEST_EPSILON = 1e6;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    RehypeDopplerHookMigratorHarness internal harness;
    MockQuoter internal mockQuoter;

    PoolKey internal testPoolKey;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        MockPoolManager mockPoolManager = new MockPoolManager();
        MockMigrator mockMigrator = new MockMigrator();
        mockQuoter = new MockQuoter();
        harness = new RehypeDopplerHookMigratorHarness(
            DopplerHookMigrator(payable(address(mockMigrator))),
            IPoolManager(address(mockPoolManager))
        );

        testPoolKey = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY A: EARLY EXIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_BothExcessBelowEpsilon_ReturnsShouldSwapFalse() public view {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 newSqrtPriceX96) =
            harness.exposed_rebalanceFeesWithQuoter(
                Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
            );

        assertFalse(shouldSwap, "shouldSwap should be false when both excess below EPSILON");
        assertFalse(zeroForOne, "zeroForOne should be false (default)");
        assertEq(amountIn, 0, "amountIn should be 0");
        assertEq(amountOut, 0, "amountOut should be 0");
        assertEq(newSqrtPriceX96, sqrtPriceX96, "sqrtPrice should be unchanged");
    }

    function test_rebalanceFees_BothExcessExactlyEpsilon_ReturnsShouldSwapFalse() public view {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(lpAmount0, lpAmount1, sqrtPriceX96);
        assertEq(excess0, 0, "Precondition: excess0 should be 0");
        assertEq(excess1, 0, "Precondition: excess1 should be 0");

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "shouldSwap should be false when excess at or below EPSILON");
    }

    function test_rebalanceFees_Excess0AboveEpsilon_EntersLoop() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "shouldSwap should be true when excess0 > EPSILON");
        assertTrue(zeroForOne, "zeroForOne should be true when swapping token0 for token1");
    }

    function test_rebalanceFees_Excess1AboveEpsilon_EntersLoop() public {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 2e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: int256(5e17),
                amount1: -5e17,
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "shouldSwap should be true when excess1 > EPSILON");
        assertFalse(zeroForOne, "zeroForOne should be false when swapping token1 for token0");
    }

    function test_rebalanceFees_BothExcessAboveEpsilon_EntersLoop() public {
        uint256 lpAmount0 = 3e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -1e18,
                amount1: int256(1e18),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "shouldSwap should be true when both excess > EPSILON");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY B: DIRECTION SELECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_Excess0Greater_ZeroForOneTrue() public {
        uint256 lpAmount0 = 3e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -1e18,
                amount1: int256(1e18),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(zeroForOne, "zeroForOne should be true when excess0 > excess1");
    }

    function test_rebalanceFees_Excess1Greater_ZeroForOneFalse() public {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 3e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: int256(1e18),
                amount1: -1e18,
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(zeroForOne, "zeroForOne should be false when excess1 > excess0");
    }

    function test_rebalanceFees_ExcessEqual_ZeroForOneTrue() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (uint256 excess0, uint256 excess1) = harness.exposed_calculateExcess(lpAmount0, lpAmount1, sqrtPriceX96);

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        if (excess0 >= excess1) {
            assertTrue(zeroForOne, "zeroForOne should be true when excess0 >= excess1");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY C: BINARY SEARCH CONVERGENCE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_ConvergesWithGoodResult() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,, uint256 amountIn,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find a valid swap");
        assertGt(amountIn, 0, "amountIn should be > 0");
    }

    function test_rebalanceFees_NeverConverges_ReturnsBest() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -4e17,
                amount1: int256(4e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "shouldSwap should be true - returns best found");
    }

    function test_rebalanceFees_AllSimulationsFail_ReturnsFalse() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: 0,
                amount1: 0,
                sqrtPriceAfterX96: 0,
                shouldRevert: true,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "shouldSwap should be false when all simulations fail");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY D: BINARY SEARCH EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_GuessZeroAdjustedToOne() public view {
        uint256 lpAmount0 = 1e18 + 2;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );
    }

    function test_rebalanceFees_HighEqualsOne_SimFails_Breaks() public {
        uint256 lpAmount0 = 1e18 + TEST_EPSILON + 1;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: 0,
                amount1: 0,
                sqrtPriceAfterX96: 0,
                shouldRevert: true,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Should return false when high=1 and sim fails");
    }

    function test_rebalanceFees_HighEqualsZero_SimFails_Breaks() public {
        uint256 lpAmount0 = 1e18 + TEST_EPSILON + 2;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: 0,
                amount1: 0,
                sqrtPriceAfterX96: 0,
                shouldRevert: true,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Should return false when high reduces to 0");
    }

    function test_rebalanceFees_HighEqualsZero_LoopNotEntered() public view {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Should return false with no excess");
    }

    function test_rebalanceFees_LoopConverges() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -4e17,
                amount1: int256(4e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should return best result");
    }

    function test_rebalanceFees_LargeImbalanceContinues() public {
        uint256 lpAmount0 = 10e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -4e18,
                amount1: int256(4e18),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find a swap");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY E: SIMULATION FAILURE HANDLING
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_SmallestSwapFails_ReturnsFalse() public {
        uint256 lpAmount0 = 1e18 + TEST_EPSILON + 1;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: 0,
                amount1: 0,
                sqrtPriceAfterX96: 0,
                shouldRevert: true,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Should return false when smallest swap fails");
    }

    function test_rebalanceFees_QuoterReverts() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: 0,
                amount1: 0,
                sqrtPriceAfterX96: 0,
                shouldRevert: true,
                revertData: abi.encodeWithSignature("CustomError()")
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Quoter revert should be handled gracefully");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY F: BEST RESULT TRACKING
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_ReturnsValidResult() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,, uint256 amountIn, uint256 amountOut,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find swap");
        assertGt(amountIn, 0, "amountIn should be > 0");
        assertGt(amountOut, 0, "amountOut should be > 0");
    }

    function test_rebalanceFees_DeterministicResult() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap1, bool zeroForOne1, uint256 amountIn1, uint256 amountOut1, uint160 sqrtPrice1) =
            harness.exposed_rebalanceFeesWithQuoter(
                Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
            );

        (bool shouldSwap2, bool zeroForOne2, uint256 amountIn2, uint256 amountOut2, uint160 sqrtPrice2) =
            harness.exposed_rebalanceFeesWithQuoter(
                Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
            );

        assertEq(shouldSwap1, shouldSwap2, "shouldSwap should be deterministic");
        assertEq(zeroForOne1, zeroForOne2, "zeroForOne should be deterministic");
        assertEq(amountIn1, amountIn2, "amountIn should be deterministic");
        assertEq(amountOut1, amountOut2, "amountOut should be deterministic");
        assertEq(sqrtPrice1, sqrtPrice2, "sqrtPrice should be deterministic");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY G: DIRECTION TESTS (zeroForOne=true)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_ZeroForOne_CorrectDirection() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find swap");
        assertTrue(zeroForOne, "Should be zeroForOne when excess0 > excess1");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CATEGORY H: DIRECTION TESTS (zeroForOne=false)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_OneForZero_CorrectDirection() public {
        uint256 lpAmount0 = 1e18;
        uint256 lpAmount1 = 2e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: int256(5e17),
                amount1: -5e17,
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap, bool zeroForOne,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find swap");
        assertFalse(zeroForOne, "Should be oneForZero when excess1 > excess0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADDITIONAL EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalanceFees_InvalidQuoterResponse_Handled() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;

        // For zeroForOne=true, amount0 should be negative, amount1 positive
        // Set invalid response (both positive)
        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: int256(5e17),
                amount1: int256(5e17),
                sqrtPriceAfterX96: SQRT_PRICE_1_1,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,,) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertFalse(shouldSwap, "Invalid quoter response should be handled");
    }

    function test_rebalanceFees_ReturnsSqrtPrice() public {
        uint256 lpAmount0 = 2e18;
        uint256 lpAmount1 = 1e18;
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;
        uint160 newSqrtPrice = SQRT_PRICE_1_1 + 1e20;

        mockQuoter.setDefaultResponse(
            MockQuoter.QuoteResponse({
                amount0: -5e17,
                amount1: int256(5e17),
                sqrtPriceAfterX96: newSqrtPrice,
                shouldRevert: false,
                revertData: ""
            })
        );

        (bool shouldSwap,,,, uint160 returnedSqrtPrice) = harness.exposed_rebalanceFeesWithQuoter(
            Quoter(address(mockQuoter)), testPoolKey, lpAmount0, lpAmount1, sqrtPriceX96
        );

        assertTrue(shouldSwap, "Should find swap");
        assertEq(returnedSqrtPrice, newSqrtPrice, "Should return new sqrt price from quoter");
    }
}
