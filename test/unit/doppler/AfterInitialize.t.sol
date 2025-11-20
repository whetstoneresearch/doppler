// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { Position } from "src/modules/initializers/Doppler.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract AfterInitializeTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint16;
    using ProtocolFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

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

        assertEq(lowerSlug.tickLower, hook.startingTick());
        assertEq(lowerSlug.tickUpper, hook.startingTick());

        // Assert that lower slug has no liquidity
        assertEq(lowerSlug.liquidity, 0);
    }

    function test_afterInitialize_RevertsWhenNotCalledByPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            0,
            0
        );
    }

    function test_afterInitialize_UpdatesDynamicLPFee() public view {
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, hook.initialLpFee(), "LP fee not set to initial value");
    }
}
