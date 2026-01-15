// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

import { WAD } from "src/types/Wad.sol";
import { RehypeHandler } from "test/invariant/rehype/RehypeHandler.sol";
import { RehypeSetup } from "test/invariant/rehype/RehypeSetup.sol";

/// @title RehypeInvariantsTest
/// @notice Invariant tests for RehypeDopplerHook with ERC20 numeraire
/// @dev Tests that swaps never revert unexpectedly and fee accounting is correct
contract RehypeInvariantsTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set up with ERC20 numeraire
        _setupRehype(false);

        // Create the token and pool
        _createToken(bytes32(uint256(1)));

        // Create handler
        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire,
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        // Configure fuzzer targets
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.changeFeeDistribution.selector;
        selectors[3] = handler.setExtremeFeeDistribution.selector;
        selectors[4] = handler.collectBeneficiaryFees.selector;
        selectors[5] = handler.buyTinyAmount.selector;
        selectors[6] = handler.buyLargeAmount.selector;
        selectors[7] = handler.rapidBuys.selector;
        selectors[8] = handler.alternateBuySell.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Exclude system addresses from being used as msg.sender
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
        excludeSender(address(tokenFactory));
        excludeSender(address(governanceFactory));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PRIMARY INVARIANTS (Must Pass)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice INV-001: Swaps must never revert unexpectedly
    /// @dev This is the primary goal of invariant testing for RehypeDopplerHook
    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "CRITICAL: Unexpected swap revert occurred");
    }

    /// @notice INV-002: Fee distribution percentages must always sum to WAD (1e18)
    function invariant_FeeDistributionSumsToWAD() public view {
        (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
            rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetBuyback + numeraireBuyback + beneficiary + lp, WAD, "Fee distribution doesn't sum to WAD");
    }

    /// @notice INV-003: Hook must always hold enough tokens to cover beneficiary fees
    function invariant_HookSolventForBeneficiaryFees() public view {
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeDopplerHook.getHookFees(poolId);

        uint256 hookBalance0 = poolKey.currency0.balanceOf(address(rehypeDopplerHook));
        uint256 hookBalance1 = poolKey.currency1.balanceOf(address(rehypeDopplerHook));

        assertGe(hookBalance0, beneficiaryFees0, "Hook insolvent: can't cover beneficiaryFees0");
        assertGe(hookBalance1, beneficiaryFees1, "Hook insolvent: can't cover beneficiaryFees1");
    }

    /// @notice INV-004: After swap processing, temporary fee variables should be below EPSILON
    /// @dev Fees below EPSILON (1e6) are intentionally not distributed to save gas
    function invariant_NoStuckTemporaryFees() public view {
        (uint128 fees0, uint128 fees1,,,,,) = rehypeDopplerHook.getHookFees(poolId);

        // EPSILON = 1e6 - fees below this threshold are intentionally not processed
        uint128 EPSILON = 1e6;
        assertLe(fees0, EPSILON, "Undistributed fees0 exceeds EPSILON threshold");
        assertLe(fees1, EPSILON, "Undistributed fees1 exceeds EPSILON threshold");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECONDARY INVARIANTS (Should Pass)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice INV-005: LP position liquidity should only increase (never decrease)
    function invariant_LPLiquidityMonotonicallyIncreases() public view {
        (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(poolId);

        assertGe(liquidity, handler.ghost_lastLiquidity(), "LP liquidity decreased unexpectedly");
    }

    /// @notice INV-006: LP position must remain full-range
    function invariant_PositionRemainsFullRange() public view {
        (int24 tickLower, int24 tickUpper,,) = rehypeDopplerHook.getPosition(poolId);

        int24 expectedTickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 expectedTickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        assertEq(tickLower, expectedTickLower, "Position tickLower changed from full range");
        assertEq(tickUpper, expectedTickUpper, "Position tickUpper changed from full range");
    }

    /// @notice INV-007: Pool info should remain immutable after initialization
    function invariant_PoolInfoImmutable() public view {
        (address storedAsset, address storedNumeraire, address storedBuybackDst) =
            rehypeDopplerHook.getPoolInfo(poolId);

        assertEq(storedAsset, address(asset), "Asset address changed");
        assertEq(storedNumeraire, address(numeraire), "Numeraire address changed");
        assertEq(storedBuybackDst, buybackDst, "BuybackDst address changed");
    }

    /// @notice INV-008: Custom fee must remain within valid bounds
    function invariant_CustomFeeWithinBounds() public view {
        (,,,,,, uint24 storedCustomFee) = rehypeDopplerHook.getHookFees(poolId);

        // MAX_SWAP_FEE = 1e6 (100%)
        assertLe(storedCustomFee, 1e6, "Custom fee exceeds maximum (1e6)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SANITY CHECK INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify the fuzzer is actually executing swaps
    function invariant_SwapsWereAttempted() public view {
        // This is a sanity check - not a hard requirement
        // Logs help verify the fuzzer is working correctly
        if (handler.ghost_totalSwapAttempts() > 0) {
            assertTrue(
                handler.ghost_successfulSwaps() > 0 || handler.ghost_expectedReverts() > 0,
                "All swap attempts failed unexpectedly (sanity check)"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CALL SUMMARY (for debugging)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Log summary of invariant test run
    /// @dev Called after each invariant run to provide visibility
    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Rehype Invariant Test Summary ===");
        console.log("Total swap attempts:      ", handler.ghost_totalSwapAttempts());
        console.log("Successful swaps:         ", handler.ghost_successfulSwaps());
        console.log("Expected reverts:         ", handler.ghost_expectedReverts());
        console.log("UNEXPECTED REVERTS:       ", handler.ghost_unexpectedReverts());
        console.log("Buy swaps:                ", handler.ghost_buySwaps());
        console.log("Sell swaps:               ", handler.ghost_sellSwaps());
        console.log("Fee distribution changes: ", handler.ghost_feeDistributionChanges());
        console.log("Fee collections:          ", handler.ghost_feeCollections());
        console.log("Liquidity additions:      ", handler.ghost_liquidityAdditions());
        console.log("Actor count:              ", handler.getActorCount());

        (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(poolId);
        console.log("Current LP liquidity:     ", liquidity);

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeDopplerHook.getHookFees(poolId);
        console.log("Beneficiary fees0:        ", beneficiaryFees0);
        console.log("Beneficiary fees1:        ", beneficiaryFees1);

        console.log("Revert selectors seen:    ", handler.getRevertSelectorCount());
        console.log("=====================================");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// ETH NUMERAIRE VARIANT
// ═══════════════════════════════════════════════════════════════════════════════════

/// @title RehypeInvariantsETHTest
/// @notice Invariant tests for RehypeDopplerHook with native ETH as numeraire
contract RehypeInvariantsETHTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set up with ETH as numeraire
        _setupRehype(true);

        // Create the token and pool
        _createToken(bytes32(uint256(2)));

        // Create handler
        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire, // Will be TestERC20(address(0)) for ETH
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        // Configure fuzzer targets (subset for ETH testing)
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.changeFeeDistribution.selector;
        selectors[3] = handler.collectBeneficiaryFees.selector;
        selectors[4] = handler.alternateBuySell.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Exclude system addresses
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
    }

    /// @notice INV-001 (ETH): Swaps must never revert unexpectedly
    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "CRITICAL: Unexpected swap revert with ETH numeraire");
    }

    /// @notice INV-002 (ETH): Fee distribution must sum to WAD
    function invariant_FeeDistributionSumsToWAD() public view {
        (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
            rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetBuyback + numeraireBuyback + beneficiary + lp, WAD, "Fee distribution doesn't sum to WAD (ETH)");
    }

    /// @notice INV-003 (ETH): Hook must be solvent
    function invariant_HookSolventForBeneficiaryFees() public view {
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeDopplerHook.getHookFees(poolId);

        uint256 hookBalance0 = poolKey.currency0.balanceOf(address(rehypeDopplerHook));
        uint256 hookBalance1 = poolKey.currency1.balanceOf(address(rehypeDopplerHook));

        assertGe(hookBalance0, beneficiaryFees0, "Hook insolvent on token0 (ETH)");
        assertGe(hookBalance1, beneficiaryFees1, "Hook insolvent on token1 (ETH)");
    }

    /// @notice INV-004 (ETH): Temporary fees should be below EPSILON
    /// @dev Fees below EPSILON (1e6) are intentionally not distributed to save gas
    function invariant_NoStuckTemporaryFees() public view {
        (uint128 fees0, uint128 fees1,,,,,) = rehypeDopplerHook.getHookFees(poolId);

        uint128 EPSILON = 1e6;
        assertLe(fees0, EPSILON, "Stuck fees0 exceeds EPSILON (ETH)");
        assertLe(fees1, EPSILON, "Stuck fees1 exceeds EPSILON (ETH)");
    }

    /// @notice Summary for ETH tests
    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Rehype ETH Invariant Test Summary ===");
        console.log("Total swap attempts: ", handler.ghost_totalSwapAttempts());
        console.log("Successful swaps:    ", handler.ghost_successfulSwaps());
        console.log("Unexpected reverts:  ", handler.ghost_unexpectedReverts());
        console.log("==========================================");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// EXTREME FEE DISTRIBUTION VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════════

/// @title RehypeInvariantsFullLPTest
/// @notice Test with 100% LP fee distribution (most complex logic path)
contract RehypeInvariantsFullLPTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set fee distribution to 100% LP
        assetBuybackPercent = 0;
        numeraireBuybackPercent = 0;
        beneficiaryPercent = 0;
        lpPercent = WAD;

        _setupRehype(false);
        _createToken(bytes32(uint256(3)));

        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire,
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        // Focus on swap functions for LP testing
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.rapidBuys.selector;
        selectors[3] = handler.alternateBuySell.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
    }

    /// @notice Swaps should not revert with 100% LP distribution
    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "Unexpected revert with 100% LP distribution");
    }

    /// @notice LP liquidity should increase with 100% LP
    function invariant_LPLiquidityIncreases() public view {
        (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(poolId);
        assertGe(liquidity, handler.ghost_lastLiquidity(), "LP liquidity didn't increase with 100% LP");
    }

    /// @notice Fee distribution should still be valid
    function invariant_FeeDistributionValid() public view {
        (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
            rehypeDopplerHook.getFeeDistributionInfo(poolId);

        assertEq(assetBuyback + numeraireBuyback + beneficiary + lp, WAD, "Invalid fee distribution");
        assertEq(lp, WAD, "LP should be 100%");
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== 100% LP Fee Distribution Test ===");
        console.log("Swaps: ", handler.ghost_successfulSwaps());
        console.log("LP additions: ", handler.ghost_liquidityAdditions());
        (,, uint128 liq,) = rehypeDopplerHook.getPosition(poolId);
        console.log("Final liquidity: ", liq);
        console.log("=====================================");
    }
}

/// @title RehypeInvariantsFullBeneficiaryTest
/// @notice Test with 100% beneficiary fee distribution
contract RehypeInvariantsFullBeneficiaryTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set fee distribution to 100% beneficiary
        assetBuybackPercent = 0;
        numeraireBuybackPercent = 0;
        beneficiaryPercent = WAD;
        lpPercent = 0;

        _setupRehype(false);
        _createToken(bytes32(uint256(4)));

        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire,
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.collectBeneficiaryFees.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
    }

    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "Unexpected revert with 100% beneficiary");
    }

    function invariant_HookSolvent() public view {
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeDopplerHook.getHookFees(poolId);

        uint256 hookBalance0 = poolKey.currency0.balanceOf(address(rehypeDopplerHook));
        uint256 hookBalance1 = poolKey.currency1.balanceOf(address(rehypeDopplerHook));

        assertGe(hookBalance0, beneficiaryFees0, "Insolvent with 100% beneficiary");
        assertGe(hookBalance1, beneficiaryFees1, "Insolvent with 100% beneficiary");
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== 100% Beneficiary Fee Test ===");
        console.log("Swaps: ", handler.ghost_successfulSwaps());
        console.log("Collections: ", handler.ghost_feeCollections());
        (,, uint128 bf0, uint128 bf1,,,) = rehypeDopplerHook.getHookFees(poolId);
        console.log("Pending fees0: ", bf0);
        console.log("Pending fees1: ", bf1);
        console.log("=================================");
    }
}

/// @title RehypeInvariantsFullAssetBuybackTest
/// @notice Test with 100% asset buyback fee distribution
contract RehypeInvariantsFullAssetBuybackTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set fee distribution to 100% asset buyback
        assetBuybackPercent = WAD;
        numeraireBuybackPercent = 0;
        beneficiaryPercent = 0;
        lpPercent = 0;

        _setupRehype(false);
        _createToken(bytes32(uint256(5)));

        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire,
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.alternateBuySell.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
    }

    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "Unexpected revert with 100% asset buyback");
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== 100% Asset Buyback Test ===");
        console.log("Swaps: ", handler.ghost_successfulSwaps());
        console.log("Buyback dst asset received: ", handler.ghost_buybackDstAssetReceived());
        console.log("===============================");
    }
}

/// @title RehypeInvariantsZeroFeeTest
/// @notice Test with zero custom fee (no fees collected)
contract RehypeInvariantsZeroFeeTest is RehypeSetup {
    RehypeHandler public handler;

    function setUp() public {
        // Set custom fee to 0
        customFee = 0;

        _setupRehype(false);
        _createToken(bytes32(uint256(6)));

        handler = new RehypeHandler(
            rehypeDopplerHook,
            initializer,
            manager,
            swapRouter,
            asset,
            numeraire,
            poolKey,
            isToken0,
            isUsingEth,
            buybackDst,
            beneficiary1
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.alternateBuySell.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(asset));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
    }

    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_unexpectedReverts(), 0, "Unexpected revert with zero fee");
    }

    /// @notice With zero fee, no beneficiary fees should accumulate
    function invariant_NoBeneficiaryFeesWithZeroFee() public view {
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeDopplerHook.getHookFees(poolId);

        assertEq(beneficiaryFees0, 0, "Beneficiary fees0 accumulated with zero fee");
        assertEq(beneficiaryFees1, 0, "Beneficiary fees1 accumulated with zero fee");
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Zero Custom Fee Test ===");
        console.log("Swaps: ", handler.ghost_successfulSwaps());
        (,,,,,, uint24 fee) = rehypeDopplerHook.getHookFees(poolId);
        console.log("Custom fee: ", fee);
        console.log("============================");
    }
}
