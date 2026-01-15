// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { WAD } from "src/types/Wad.sol";
import { MultiPoolRehypeHandler } from "test/invariant/rehype/multi/MultiPoolRehypeHandler.sol";
import { MultiPoolRehypeSetup, PoolConfig } from "test/invariant/rehype/multi/MultiPoolRehypeSetup.sol";

/// @title MultiPoolRehypeInvariantsTest
/// @notice Invariant tests for RehypeDopplerHook with multiple concurrent pools
/// @dev Tests pool isolation, cross-pool consistency, and global solvency
contract MultiPoolRehypeInvariantsTest is MultiPoolRehypeSetup {
    MultiPoolRehypeHandler public handler;

    function setUp() public {
        // Set up with ERC20 numeraire and 3 pools with different configs
        _setupMultiPoolRehype(false);

        // Create handler
        handler = new MultiPoolRehypeHandler(this);

        // Configure fuzzer targets
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.buyOnPool.selector;
        selectors[1] = handler.sellOnPool.selector;
        selectors[2] = handler.swapCrossPool.selector;
        selectors[3] = handler.swapAllPoolsRoundRobin.selector;
        selectors[4] = handler.changePoolFeeDistribution.selector;
        selectors[5] = handler.setExtremePoolFeeDistribution.selector;
        selectors[6] = handler.collectFeesFromPool.selector;
        selectors[7] = handler.stressSinglePool.selector;
        selectors[8] = handler.rapidCrossPoolSwaps.selector;
        selectors[9] = handler.buyTinyAmountOnPool.selector;
        selectors[10] = handler.buyLargeAmountOnPool.selector;
        // Leave room for expansion

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Exclude system addresses
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
        excludeSender(address(tokenFactory));
        excludeSender(address(governanceFactory));

        // Exclude all asset addresses
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            excludeSender(address(getAsset(i)));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PRIMARY INVARIANTS - From original single-pool tests, extended to multi-pool
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice INV-001: Swaps must never revert unexpectedly on ANY pool
    /// @dev This is the primary goal - extended to all pools
    function invariant_SwapsNeverRevertUnexpectedlyAnyPool() public view {
        assertEq(
            handler.ghost_totalUnexpectedRevertsAllPools(),
            0,
            "CRITICAL: Unexpected swap revert occurred on at least one pool"
        );
    }

    /// @notice INV-002: Fee distribution percentages must sum to WAD for EACH pool
    function invariant_FeeDistributionSumsToWADPerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
                rehypeDopplerHook.getFeeDistributionInfo(poolId);

            assertEq(
                assetBuyback + numeraireBuyback + beneficiary + lp,
                WAD,
                string(abi.encodePacked("Fee distribution doesn't sum to WAD for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-003: Hook must hold enough tokens to cover beneficiary fees for EACH pool
    function invariant_HookSolventForBeneficiaryFeesPerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            PoolKey memory key = getPoolKey(i);

            (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,) = rehypeDopplerHook.getHookFees(poolId);

            uint256 hookBalance0 = key.currency0.balanceOf(address(rehypeDopplerHook));
            uint256 hookBalance1 = key.currency1.balanceOf(address(rehypeDopplerHook));

            assertGe(
                hookBalance0,
                beneficiaryFees0,
                string(abi.encodePacked("Hook insolvent on token0 for pool ", vm.toString(i)))
            );
            assertGe(
                hookBalance1,
                beneficiaryFees1,
                string(abi.encodePacked("Hook insolvent on token1 for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-004: Temporary fee variables should be at or below EPSILON for EACH pool
    function invariant_NoStuckTemporaryFeesPerPool() public view {
        uint128 EPSILON = 1e6;

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (uint128 fees0, uint128 fees1,,,) = rehypeDopplerHook.getHookFees(poolId);

            assertLe(
                fees0,
                EPSILON,
                string(abi.encodePacked("Undistributed fees0 exceeds EPSILON for pool ", vm.toString(i)))
            );
            assertLe(
                fees1,
                EPSILON,
                string(abi.encodePacked("Undistributed fees1 exceeds EPSILON for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-005: LP liquidity should only increase for EACH pool
    function invariant_LPLiquidityMonotonicallyIncreasesPerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(poolId);

            assertGe(
                liquidity,
                handler.ghost_lastLiquidityPerPool(i),
                string(abi.encodePacked("LP liquidity decreased for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-006: LP position must remain full-range for EACH pool
    function invariant_PositionRemainsFullRangePerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            PoolKey memory key = getPoolKey(i);

            (int24 tickLower, int24 tickUpper,,) = rehypeDopplerHook.getPosition(poolId);

            int24 expectedTickLower = TickMath.minUsableTick(key.tickSpacing);
            int24 expectedTickUpper = TickMath.maxUsableTick(key.tickSpacing);

            assertEq(
                tickLower,
                expectedTickLower,
                string(abi.encodePacked("Position tickLower wrong for pool ", vm.toString(i)))
            );
            assertEq(
                tickUpper,
                expectedTickUpper,
                string(abi.encodePacked("Position tickUpper wrong for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-007: Pool info should remain immutable for EACH pool
    function invariant_PoolInfoImmutablePerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (address storedAsset, address storedNumeraire, address storedBuybackDst) =
                rehypeDopplerHook.getPoolInfo(poolId);

            assertEq(
                storedAsset,
                address(getAsset(i)),
                string(abi.encodePacked("Asset changed for pool ", vm.toString(i)))
            );
            assertEq(
                storedNumeraire,
                address(numeraire),
                string(abi.encodePacked("Numeraire changed for pool ", vm.toString(i)))
            );
            assertEq(
                storedBuybackDst,
                buybackDst,
                string(abi.encodePacked("BuybackDst changed for pool ", vm.toString(i)))
            );
        }
    }

    /// @notice INV-008: Custom fee must remain within bounds for EACH pool
    function invariant_CustomFeeWithinBoundsPerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (,,,, uint24 storedCustomFee) = rehypeDopplerHook.getHookFees(poolId);

            assertLe(
                storedCustomFee,
                1e6,
                string(abi.encodePacked("Custom fee exceeds max for pool ", vm.toString(i)))
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // NEW MULTI-POOL INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice INV-009: Pool state must be isolated - operations on pool A shouldn't affect pool B
    /// @dev This checks that fee distributions differ between pools with different initial configs
    function invariant_PoolStateIsolation() public view {
        // Verify pools maintain their distinct configurations unless explicitly changed
        // We check that pools with different initial LP percentages still differ
        // (unless the fuzzer changed them to be the same)

        // Get initial configs
        PoolConfig memory config0 = _poolConfigs[0];
        PoolConfig memory config1 = _poolConfigs[1];
        PoolConfig memory config2 = _poolConfigs[2];

        // Get current state
        (,,, uint256 lp0) = rehypeDopplerHook.getFeeDistributionInfo(getPoolId(0));
        (,,, uint256 lp1) = rehypeDopplerHook.getFeeDistributionInfo(getPoolId(1));
        (,,, uint256 lp2) = rehypeDopplerHook.getFeeDistributionInfo(getPoolId(2));

        // If no fee distribution changes happened, configs should match initial
        if (handler.ghost_feeDistributionChangesPerPool(0) == 0) {
            assertEq(lp0, config0.lpPercent, "Pool 0 LP config changed without explicit change");
        }
        if (handler.ghost_feeDistributionChangesPerPool(1) == 0) {
            assertEq(lp1, config1.lpPercent, "Pool 1 LP config changed without explicit change");
        }
        if (handler.ghost_feeDistributionChangesPerPool(2) == 0) {
            assertEq(lp2, config2.lpPercent, "Pool 2 LP config changed without explicit change");
        }
    }

    /// @notice INV-010: Global solvency - hook must be solvent across ALL pools combined
    /// @dev Sum of all beneficiary fees across all pools must be <= hook balance
    function invariant_GlobalSolvency() public view {
        // Track total owed per unique currency
        // Since all pools share the same numeraire, we can sum numeraire fees

        uint256 totalNumeraireFees;
        uint256 hookNumeraireBalance = numeraire.balanceOf(address(rehypeDopplerHook));

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            bool isToken0 = getIsToken0(i);
            (,, uint128 bf0, uint128 bf1,) = rehypeDopplerHook.getHookFees(poolId);

            // Numeraire is token1 if asset is token0, else token0
            totalNumeraireFees += isToken0 ? bf1 : bf0;
        }

        assertGe(
            hookNumeraireBalance,
            totalNumeraireFees,
            "Global insolvency: hook cannot cover all pools' numeraire beneficiary fees"
        );
    }

    /// @notice INV-011: Cross-pool LP independence - LP positions are independent
    function invariant_CrossPoolLPIndependence() public view {
        // Each pool's position should have correct tick bounds for its tick spacing
        // and liquidity should match ghost tracking

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            PoolKey memory key = getPoolKey(i);

            (int24 tickLower, int24 tickUpper, uint128 liquidity,) = rehypeDopplerHook.getPosition(poolId);

            // Verify tick bounds match this pool's tick spacing
            assertEq(tickLower, TickMath.minUsableTick(key.tickSpacing), "Tick lower doesn't match tick spacing");
            assertEq(tickUpper, TickMath.maxUsableTick(key.tickSpacing), "Tick upper doesn't match tick spacing");

            // Verify liquidity is >= ghost tracking (monotonic)
            assertGe(liquidity, handler.ghost_lastLiquidityPerPool(i), "Liquidity below ghost tracking");
        }
    }

    /// @notice INV-012: Position salt uniqueness - each pool must have unique position salt
    function invariant_PositionSaltUniqueness() public view {
        bytes32[] memory salts = new bytes32[](NUM_POOLS);

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (,,, bytes32 salt) = rehypeDopplerHook.getPosition(poolId);
            salts[i] = salt;

            // Check against all previous salts
            for (uint256 j = 0; j < i; j++) {
                assertTrue(
                    salts[j] != salt,
                    string(
                        abi.encodePacked(
                            "Duplicate position salt between pool ", vm.toString(j), " and ", vm.toString(i)
                        )
                    )
                );
            }
        }
    }

    /// @notice INV-013: Per-pool fee distribution validity (redundant with INV-002 but explicit)
    function invariant_PerPoolFeeDistributionValidity() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            (uint256 a, uint256 n, uint256 b, uint256 l) = rehypeDopplerHook.getFeeDistributionInfo(poolId);

            // Sum must equal WAD
            assertEq(a + n + b + l, WAD, "Fee distribution invalid");

            // Each component must be <= WAD
            assertLe(a, WAD, "Asset buyback exceeds WAD");
            assertLe(n, WAD, "Numeraire buyback exceeds WAD");
            assertLe(b, WAD, "Beneficiary exceeds WAD");
            assertLe(l, WAD, "LP exceeds WAD");
        }
    }

    /// @notice INV-014: No unexpected reverts on any pool (same as INV-001, explicit check)
    function invariant_NoUnexpectedRevertsPerPool() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            assertEq(
                handler.ghost_unexpectedRevertsPerPool(i),
                0,
                string(abi.encodePacked("Unexpected reverts on pool ", vm.toString(i)))
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SANITY CHECK INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify the fuzzer is exercising all pools
    function invariant_AllPoolsExercised() public view {
        // This is a sanity check - not a hard requirement
        // In a sufficiently long run, all pools should see some activity
        if (handler.ghost_totalSwapAttemptsAllPools() > 50) {
            for (uint256 i = 0; i < NUM_POOLS; i++) {
                assertTrue(
                    handler.ghost_swapAttemptsPerPool(i) > 0,
                    string(abi.encodePacked("Pool ", vm.toString(i), " never exercised"))
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CALL SUMMARY
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Log summary of invariant test run
    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Multi-Pool Rehype Invariant Test Summary ===");
        console.log("Total pools:                   ", NUM_POOLS);
        console.log("Total swap attempts (all):     ", handler.ghost_totalSwapAttemptsAllPools());
        console.log("Total successful swaps (all):  ", handler.ghost_totalSuccessfulSwapsAllPools());
        console.log("Total expected reverts (all):  ", handler.ghost_totalExpectedRevertsAllPools());
        console.log("UNEXPECTED REVERTS (all):      ", handler.ghost_totalUnexpectedRevertsAllPools());
        console.log("Cross-pool swap operations:    ", handler.ghost_crossPoolSwapCount());
        console.log("Fee distribution changes:      ", handler.ghost_totalFeeDistributionChanges());
        console.log("Fee collections:               ", handler.ghost_totalFeeCollections());
        console.log("");

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            console.log("--- Pool", i, "---");
            console.log("  Swap attempts:        ", handler.ghost_swapAttemptsPerPool(i));
            console.log("  Successful swaps:     ", handler.ghost_successfulSwapsPerPool(i));
            console.log("  Unexpected reverts:   ", handler.ghost_unexpectedRevertsPerPool(i));

            (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(getPoolId(i));
            console.log("  Current LP liquidity: ", liquidity);

            (,, uint128 bf0, uint128 bf1,) = rehypeDopplerHook.getHookFees(getPoolId(i));
            console.log("  Beneficiary fees0:    ", bf0);
            console.log("  Beneficiary fees1:    ", bf1);

            PoolConfig memory config = _poolConfigs[i];
            console.log("  Tick spacing:         ", uint256(uint24(config.tickSpacing)));
            console.log("  Custom fee:           ", config.customFee);
        }

        console.log("");
        console.log("Actor count:                   ", handler.getActorCount());
        console.log("Revert selectors seen:         ", handler.getRevertSelectorCount());
        console.log("================================================");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// ETH NUMERAIRE VARIANT
// ═══════════════════════════════════════════════════════════════════════════════════

/// @title MultiPoolRehypeInvariantsETHTest
/// @notice Multi-pool invariant tests with native ETH as numeraire
contract MultiPoolRehypeInvariantsETHTest is MultiPoolRehypeSetup {
    MultiPoolRehypeHandler public handler;

    function setUp() public {
        // Set up with ETH as numeraire
        _setupMultiPoolRehype(true);

        // Create handler
        handler = new MultiPoolRehypeHandler(this);

        // Configure fuzzer targets (subset for ETH testing)
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.buyOnPool.selector;
        selectors[1] = handler.sellOnPool.selector;
        selectors[2] = handler.swapCrossPool.selector;
        selectors[3] = handler.swapAllPoolsRoundRobin.selector;
        selectors[4] = handler.changePoolFeeDistribution.selector;
        selectors[5] = handler.collectFeesFromPool.selector;
        selectors[6] = handler.stressSinglePool.selector;
        selectors[7] = handler.rapidCrossPoolSwaps.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Exclude system addresses
        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            excludeSender(address(getAsset(i)));
        }
    }

    /// @notice INV-001 (ETH): Swaps must never revert unexpectedly
    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(
            handler.ghost_totalUnexpectedRevertsAllPools(),
            0,
            "CRITICAL: Unexpected revert with ETH numeraire multi-pool"
        );
    }

    /// @notice INV-002 (ETH): Fee distribution must sum to WAD per pool
    function invariant_FeeDistributionSumsToWAD() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            (uint256 a, uint256 n, uint256 b, uint256 l) = rehypeDopplerHook.getFeeDistributionInfo(getPoolId(i));
            assertEq(a + n + b + l, WAD, "Fee distribution invalid (ETH)");
        }
    }

    /// @notice INV-003 (ETH): Hook must be solvent per pool
    function invariant_HookSolventForBeneficiaryFees() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolKey memory key = getPoolKey(i);
            (,, uint128 bf0, uint128 bf1,) = rehypeDopplerHook.getHookFees(getPoolId(i));

            uint256 hookBalance0 = key.currency0.balanceOf(address(rehypeDopplerHook));
            uint256 hookBalance1 = key.currency1.balanceOf(address(rehypeDopplerHook));

            assertGe(hookBalance0, bf0, "Hook insolvent on token0 (ETH)");
            assertGe(hookBalance1, bf1, "Hook insolvent on token1 (ETH)");
        }
    }

    /// @notice INV-010 (ETH): Global solvency with ETH
    function invariant_GlobalSolvency() public view {
        // For ETH, check hook's ETH balance
        uint256 totalETHFees;

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            PoolId poolId = getPoolId(i);
            bool isToken0 = getIsToken0(i);
            (,, uint128 bf0, uint128 bf1,) = rehypeDopplerHook.getHookFees(poolId);

            // ETH (numeraire) is token1 if asset is token0, else token0
            // Actually for ETH, Currency.wrap(address(0)) represents ETH
            // and balanceOf will check address.balance
            totalETHFees += isToken0 ? bf1 : bf0;
        }

        uint256 hookETHBalance = address(rehypeDopplerHook).balance;
        assertGe(hookETHBalance, totalETHFees, "Global insolvency: insufficient ETH");
    }

    /// @notice Summary for ETH multi-pool tests
    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Multi-Pool ETH Rehype Invariant Test Summary ===");
        console.log("Total pools:           ", NUM_POOLS);
        console.log("Total swap attempts:   ", handler.ghost_totalSwapAttemptsAllPools());
        console.log("Successful swaps:      ", handler.ghost_totalSuccessfulSwapsAllPools());
        console.log("Unexpected reverts:    ", handler.ghost_totalUnexpectedRevertsAllPools());
        console.log("Cross-pool swaps:      ", handler.ghost_crossPoolSwapCount());
        console.log("===================================================");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// EXTREME CONFIGURATION VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════════

/// @title MultiPoolAllFullLPTest
/// @notice All pools configured with 100% LP fee distribution
contract MultiPoolAllFullLPTest is MultiPoolRehypeSetup {
    MultiPoolRehypeHandler public handler;

    function _initializePoolConfigs() internal override {
        // All pools: 100% LP, varying tick spacings and fees
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 8,
                customFee: 1000,
                assetBuybackPercent: 0,
                numeraireBuybackPercent: 0,
                beneficiaryPercent: 0,
                lpPercent: WAD
            })
        );

        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 60,
                customFee: 5000,
                assetBuybackPercent: 0,
                numeraireBuybackPercent: 0,
                beneficiaryPercent: 0,
                lpPercent: WAD
            })
        );

        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 200,
                customFee: 10000,
                assetBuybackPercent: 0,
                numeraireBuybackPercent: 0,
                beneficiaryPercent: 0,
                lpPercent: WAD
            })
        );
    }

    function setUp() public {
        _setupMultiPoolRehype(false);
        handler = new MultiPoolRehypeHandler(this);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buyOnPool.selector;
        selectors[1] = handler.sellOnPool.selector;
        selectors[2] = handler.swapCrossPool.selector;
        selectors[3] = handler.swapAllPoolsRoundRobin.selector;
        selectors[4] = handler.stressSinglePool.selector;
        selectors[5] = handler.rapidCrossPoolSwaps.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
        excludeSender(address(tokenFactory));
        excludeSender(address(governanceFactory));

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            excludeSender(address(getAsset(i)));
        }
    }

    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_totalUnexpectedRevertsAllPools(), 0, "Unexpected revert with all 100% LP");
    }

    function invariant_LPLiquidityIncreases() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            (,, uint128 liquidity,) = rehypeDopplerHook.getPosition(getPoolId(i));
            assertGe(liquidity, handler.ghost_lastLiquidityPerPool(i), "LP liquidity didn't increase");
        }
    }

    function invariant_AllPoolsFullLP() public view {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            (,,, uint256 lp) = rehypeDopplerHook.getFeeDistributionInfo(getPoolId(i));
            assertEq(lp, WAD, "Pool should be 100% LP");
        }
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== All 100% LP Multi-Pool Test ===");
        console.log("Total swaps:       ", handler.ghost_totalSuccessfulSwapsAllPools());
        console.log("Cross-pool swaps:  ", handler.ghost_crossPoolSwapCount());
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            (,, uint128 liq,) = rehypeDopplerHook.getPosition(getPoolId(i));
            console.log("Pool", i, "liquidity:", liq);
        }
        console.log("===================================");
    }
}

/// @title MultiPoolVaryingFeesTest
/// @notice Pools with widely varying custom fees (0%, 1%, 5%)
contract MultiPoolVaryingFeesTest is MultiPoolRehypeSetup {
    MultiPoolRehypeHandler public handler;

    function _initializePoolConfigs() internal override {
        // Pool 0: Zero fee
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 8,
                customFee: 0,
                assetBuybackPercent: 0.25e18,
                numeraireBuybackPercent: 0.25e18,
                beneficiaryPercent: 0.25e18,
                lpPercent: 0.25e18
            })
        );

        // Pool 1: 1% fee
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 8,
                customFee: 10000,
                assetBuybackPercent: 0.25e18,
                numeraireBuybackPercent: 0.25e18,
                beneficiaryPercent: 0.25e18,
                lpPercent: 0.25e18
            })
        );

        // Pool 2: 5% fee
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 8,
                customFee: 50000,
                assetBuybackPercent: 0.25e18,
                numeraireBuybackPercent: 0.25e18,
                beneficiaryPercent: 0.25e18,
                lpPercent: 0.25e18
            })
        );
    }

    function setUp() public {
        _setupMultiPoolRehype(false);
        handler = new MultiPoolRehypeHandler(this);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buyOnPool.selector;
        selectors[1] = handler.sellOnPool.selector;
        selectors[2] = handler.swapCrossPool.selector;
        selectors[3] = handler.swapAllPoolsRoundRobin.selector;
        selectors[4] = handler.stressSinglePool.selector;
        selectors[5] = handler.rapidCrossPoolSwaps.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(rehypeDopplerHook));
        excludeSender(address(initializer));
        excludeSender(address(numeraire));
        excludeSender(address(swapRouter));
        excludeSender(address(manager));
        excludeSender(address(airlock));
        excludeSender(address(tokenFactory));
        excludeSender(address(governanceFactory));

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            excludeSender(address(getAsset(i)));
        }
    }

    function invariant_SwapsNeverRevertUnexpectedly() public view {
        assertEq(handler.ghost_totalUnexpectedRevertsAllPools(), 0, "Unexpected revert with varying fees");
    }

    function invariant_ZeroFeePoolNoFees() public view {
        // Pool 0 has zero custom fee, so no beneficiary fees should accumulate
        (,, uint128 bf0, uint128 bf1,) = rehypeDopplerHook.getHookFees(getPoolId(0));
        assertEq(bf0, 0, "Zero-fee pool accumulated fees0");
        assertEq(bf1, 0, "Zero-fee pool accumulated fees1");
    }

    function invariant_CustomFeesPreserved() public view {
        (,,,, uint24 fee0) = rehypeDopplerHook.getHookFees(getPoolId(0));
        (,,,, uint24 fee1) = rehypeDopplerHook.getHookFees(getPoolId(1));
        (,,,, uint24 fee2) = rehypeDopplerHook.getHookFees(getPoolId(2));

        assertEq(fee0, 0, "Pool 0 fee changed");
        assertEq(fee1, 10000, "Pool 1 fee changed");
        assertEq(fee2, 50000, "Pool 2 fee changed");
    }

    function invariant_CallSummary() public view {
        console.log("");
        console.log("=== Varying Fees Multi-Pool Test ===");
        console.log("Pool 0 (0% fee) swaps:   ", handler.ghost_swapAttemptsPerPool(0));
        console.log("Pool 1 (1% fee) swaps:   ", handler.ghost_swapAttemptsPerPool(1));
        console.log("Pool 2 (5% fee) swaps:   ", handler.ghost_swapAttemptsPerPool(2));
        console.log("====================================");
    }
}
