pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";

import {BaseTest} from "test/shared/BaseTest.sol";
import {Position} from "../../src/Doppler.sol";

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
        Position memory priceDiscoverySlug = hook.getPositions(bytes32(uint256(3)));

        // Get global ticks
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(tickAccumulator, poolKey.tickSpacing);

        // Assert that all slugs are continuous
        assertEq(tickLower, lowerSlug.tickLower);
        assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
        assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
        assertEq(priceDiscoverySlug.tickUpper, tickUpper);

        // Assert that upper and price discovery slugs have liquidity
        assertNotEq(upperSlug.liquidity, 0);
        assertNotEq(priceDiscoverySlug.liquidity, 0);

        // Assert that lower slug has both ticks as the startingTick
        assertEq(lowerSlug.tickLower, hook.getStartingTick());
        assertEq(lowerSlug.tickUpper, hook.getStartingTick());

        // Assert that lower slug has no liquidity
        assertEq(lowerSlug.liquidity, 0);
    }
}
