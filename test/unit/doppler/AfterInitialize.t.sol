// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { toBalanceDelta } from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";
import { PoolId, PoolIdLibrary } from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";

import { BaseTest } from "test/shared/BaseTest.sol";
import { Position } from "src/Doppler.sol";

contract AfterInitializeTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    // =========================================================================
    //                      afterInitialize Unit Tests
    // =========================================================================

    function testAfterInitialize() public view {
        // We've already initialized in the setUp, so we just need to validate
        // that all state is as expected

        PoolKey memory poolKey = key;
        (, int256 tickAccumulator,,,,) = hook.state();

        // Get the slugs
        Position memory lowerSlug = hook.getPositions(bytes32(uint256(1)));
        Position memory upperSlug = hook.getPositions(bytes32(uint256(2)));
        Position[] memory priceDiscoverySlugs = new Position[](hook.getNumPDSlugs());
        for (uint256 i; i < hook.getNumPDSlugs(); i++) {
            priceDiscoverySlugs[i] = hook.getPositions(bytes32(uint256(3 + i)));
        }

        // Get global ticks
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Assert that all slugs are continuous
        assertEq(tickLower, lowerSlug.tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

        for (uint256 i; i < priceDiscoverySlugs.length; ++i) {
            if (i == 0) {
                assertEq(upperSlug.tickUpper, priceDiscoverySlugs[i].tickLower);
            } else {
                assertEq(priceDiscoverySlugs[i - 1].tickUpper, priceDiscoverySlugs[i].tickLower);
            }

            if (i == priceDiscoverySlugs.length - 1) {
                // We allow some room for rounding down to the nearest tickSpacing for each slug
                assertApproxEqAbs(
                    priceDiscoverySlugs[i].tickUpper,
                    tickUpper,
                    hook.getNumPDSlugs() * uint256(int256(poolKey.tickSpacing))
                );
            }

            // Validate that each price discovery slug has liquidity
            assertGt(priceDiscoverySlugs[i].liquidity, 0);
        }

        // Assert that upper and price discovery slugs have liquidity
        assertNotEq(upperSlug.liquidity, 0);

        assertEq(lowerSlug.tickLower, hook.getStartingTick());
        assertEq(lowerSlug.tickUpper, hook.getStartingTick());

        // Assert that lower slug has no liquidity
        assertEq(lowerSlug.liquidity, 0);
    }
}
