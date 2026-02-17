// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";

/// @title TickMathRoundTrip
/// @notice Fuzz tests verifying tick -> sqrtPrice -> tick round-trip equality
/// @dev Addresses PR review feedback on OpeningAuction.sol:1422
///      The validation at line 1422 assumes: tick == getTickAtSqrtPrice(getSqrtPriceAtTick(tick))
///      This test suite proves this property holds for all valid ticks.
contract TickMathRoundTrip is Test {
    /// @notice Fuzz test: tick -> sqrtPrice -> tick round-trip equality
    /// @dev This is the core property that OpeningAuction relies on at line 1422
    /// @param tick Any tick value (will be bounded to valid range)
    function testFuzz_tickToSqrtPriceToTick_roundTrip(int24 tick) public pure {
        // Bound tick to valid range
        // Note: MAX_TICK cannot be used directly because getTickAtSqrtPrice requires sqrtPrice < MAX_SQRT_PRICE
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));

        // Step 1: Convert tick to sqrtPrice (this is what _sqrtPriceLimitX96() does)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        // Step 2: Convert sqrtPrice back to tick (this is what line 1421 does)
        int24 recoveredTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Assert: The round-trip preserves the original tick
        assertEq(recoveredTick, tick, "Round-trip should preserve tick value");
    }

    /// @notice Fuzz test: round-trip for ticks aligned to common tick spacings
    /// @dev OpeningAuction enforces minAcceptableTick % tickSpacing == 0
    /// @param tick Any tick value (will be bounded and aligned)
    /// @param tickSpacing Tick spacing to test (will be bounded to valid range)
    function testFuzz_tickToSqrtPriceToTick_alignedTicks(int24 tick, int24 tickSpacing) public pure {
        // Bound tick spacing to valid range (1 to 32767)
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        // Bound tick to valid range
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));

        // Align tick to tick spacing (as OpeningAuction requires)
        tick = (tick / tickSpacing) * tickSpacing;

        // Skip if alignment pushes us out of valid range
        if (tick < TickMath.MIN_TICK) return;

        // Round-trip conversion
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        int24 recoveredTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        assertEq(recoveredTick, tick, "Round-trip should preserve aligned tick value");
    }

    /// @notice Test round-trip at boundary ticks
    function test_tickToSqrtPriceToTick_boundaries() public pure {
        // MIN_TICK
        {
            int24 tick = TickMath.MIN_TICK;
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
            int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);
            assertEq(recovered, tick, "MIN_TICK round-trip failed");
        }

        // MAX_TICK - 1 (MAX_TICK cannot be used as getTickAtSqrtPrice requires sqrtPrice < MAX_SQRT_PRICE)
        {
            int24 tick = TickMath.MAX_TICK - 1;
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
            int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);
            assertEq(recovered, tick, "MAX_TICK-1 round-trip failed");
        }

        // Zero tick
        {
            int24 tick = 0;
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
            int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);
            assertEq(recovered, tick, "Zero tick round-trip failed");
        }

        // -1 tick
        {
            int24 tick = -1;
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
            int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);
            assertEq(recovered, tick, "Negative one tick round-trip failed");
        }

        // 1 tick
        {
            int24 tick = 1;
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
            int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);
            assertEq(recovered, tick, "Positive one tick round-trip failed");
        }
    }

    /// @notice Test round-trip for ticks used in typical OpeningAuction configurations
    /// @dev Tests common minAcceptableTick values with typical tick spacings
    function test_tickToSqrtPriceToTick_typicalAuctionTicks() public pure {
        // Common tick spacings: 1, 10, 60, 100, 200
        int24[5] memory tickSpacings = [int24(1), int24(10), int24(60), int24(100), int24(200)];

        // Test a range of ticks that might be used as minAcceptableTick
        int24[10] memory testTicks = [
            int24(-887220), // Near MIN_TICK, aligned to 60
            int24(-500000), // Large negative
            int24(-100000), // Medium negative
            int24(-34020), // Default minAcceptableTick in tests
            int24(-10000), // Small negative
            int24(-60), // Single spacing negative
            int24(0), // Zero
            int24(60), // Single spacing positive
            int24(10000), // Small positive
            int24(500000) // Large positive
        ];

        for (uint256 i = 0; i < tickSpacings.length; i++) {
            int24 spacing = tickSpacings[i];
            for (uint256 j = 0; j < testTicks.length; j++) {
                int24 tick = testTicks[j];

                // Align to spacing
                tick = (tick / spacing) * spacing;

                // Skip invalid ticks
                if (tick < TickMath.MIN_TICK || tick >= TickMath.MAX_TICK) continue;

                uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
                int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);

                assertEq(
                    recovered,
                    tick,
                    string.concat(
                        "Round-trip failed for tick=",
                        vm.toString(tick),
                        " spacing=",
                        vm.toString(spacing)
                    )
                );
            }
        }
    }

    /// @notice Fuzz test: verifies the property that getSqrtPriceAtTick returns the minimum sqrtPrice for a tick
    /// @dev This explains WHY the round-trip works: getSqrtPriceAtTick(t) is the floor of the tick's price range
    /// @param tick Any tick value
    function testFuzz_sqrtPriceAtTick_isFloorOfTickRange(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));

        uint160 sqrtPriceAtTick = TickMath.getSqrtPriceAtTick(tick);
        uint160 sqrtPriceAtNextTick = TickMath.getSqrtPriceAtTick(tick + 1);

        // The sqrtPrice at tick is strictly less than sqrtPrice at tick+1
        assertTrue(sqrtPriceAtTick < sqrtPriceAtNextTick, "Price must increase with tick");

        // getTickAtSqrtPrice returns tick for all prices in [sqrtPriceAtTick, sqrtPriceAtNextTick)
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceAtTick), tick, "Floor price should map back to tick");

        // Price just below next tick should still map to current tick
        if (sqrtPriceAtNextTick > sqrtPriceAtTick + 1) {
            assertEq(
                TickMath.getTickAtSqrtPrice(sqrtPriceAtNextTick - 1),
                tick,
                "Price just below next tick should map to current tick"
            );
        }
    }

    /// @notice Test that simulates the exact flow in OpeningAuction settlement
    /// @dev Mimics: _auctionPriceLimitTick() -> _sqrtPriceLimitX96() -> swap -> getTickAtSqrtPrice -> _tickViolatesPriceLimit
    function test_openingAuctionSettlementFlow_token0() public pure {
        // Simulate isToken0 = true scenario
        int24 minAcceptableTickToken0 = -34020; // From test defaults
        int24 tickSpacing = 60;

        // Verify tick is properly aligned (as constructor enforces)
        assertEq(minAcceptableTickToken0 % tickSpacing, 0, "Tick must be aligned");

        // Step 1: _auctionPriceLimitTick() returns minAcceptableTickToken0 for isToken0=true
        int24 priceLimitTick = minAcceptableTickToken0;

        // Step 2: _sqrtPriceLimitX96() converts to sqrtPrice
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(priceLimitTick);

        // Verify it's within valid bounds (as _sqrtPriceLimitX96 checks)
        assertTrue(sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE, "Must be above MIN_SQRT_PRICE");
        assertTrue(sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE, "Must be below MAX_SQRT_PRICE");

        // Step 3: After swap, pool's sqrtPrice is retrieved and converted back to tick
        // In the best case, the swap stops exactly at the limit price
        int24 finalTick = TickMath.getTickAtSqrtPrice(sqrtPriceLimitX96);

        // Step 4: _tickViolatesPriceLimit checks: isToken0 ? (tick < limit) : (tick > limit)
        // For isToken0=true, we sell token0, price decreases, so we want tick >= limit
        bool violatesLimit = finalTick < priceLimitTick;

        // The round-trip should preserve the tick, so no violation
        assertFalse(violatesLimit, "Round-trip tick should not violate limit");
        assertEq(finalTick, priceLimitTick, "Final tick should equal limit tick");
    }

    /// @notice Test that simulates the exact flow in OpeningAuction settlement for token1
    /// @dev Mimics the isToken0=false case where _auctionPriceLimitTick returns -minAcceptableTickToken1
    function test_openingAuctionSettlementFlow_token1() public pure {
        // Simulate isToken0 = false scenario
        int24 minAcceptableTickToken1 = 34020; // Positive tick for token1 floor
        int24 tickSpacing = 60;

        // Verify tick is properly aligned
        assertEq(minAcceptableTickToken1 % tickSpacing, 0, "Tick must be aligned");

        // Step 1: _auctionPriceLimitTick() returns -minAcceptableTickToken1 for isToken0=false
        int24 priceLimitTick = -minAcceptableTickToken1;

        // Step 2: _sqrtPriceLimitX96() converts to sqrtPrice
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(priceLimitTick);

        // Step 3: After swap, convert back to tick
        int24 finalTick = TickMath.getTickAtSqrtPrice(sqrtPriceLimitX96);

        // Step 4: _tickViolatesPriceLimit checks: isToken0 ? (tick < limit) : (tick > limit)
        // For isToken0=false, we sell token1, price increases, so we want tick <= limit
        bool violatesLimit = finalTick > priceLimitTick;

        assertFalse(violatesLimit, "Round-trip tick should not violate limit");
        assertEq(finalTick, priceLimitTick, "Final tick should equal limit tick");
    }

    /// @notice Fuzz test specifically for the negative tick case used in _auctionPriceLimitTick for token1
    /// @dev When isToken0=false, the limit tick is -minAcceptableTickToken1
    function testFuzz_negatedTick_roundTrip(int24 minAcceptableTickToken1) public pure {
        // Bound to positive values (as minAcceptableTickToken1 is stored as positive)
        minAcceptableTickToken1 = int24(bound(minAcceptableTickToken1, 1, TickMath.MAX_TICK - 1));

        // The actual limit tick used is the negation
        int24 priceLimitTick = -minAcceptableTickToken1;

        // Verify it's in valid range
        if (priceLimitTick < TickMath.MIN_TICK) return;

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(priceLimitTick);
        int24 recovered = TickMath.getTickAtSqrtPrice(sqrtPrice);

        assertEq(recovered, priceLimitTick, "Negated tick round-trip failed");
    }
}
