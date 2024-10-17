pragma solidity 0.8.26;

import {BaseTest} from "../shared/BaseTest.sol";
import {SlugVis} from "../shared/SlugVis.sol";
import {SlugData} from "../../src/Doppler.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract SlugVisTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    function testSlugVis() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;

        buy(1 ether);

        SlugVis.visualizeSlugs(
            hook.getNumPDSlugs(), block.timestamp, hook.getCurrentTick(poolKey.toId()), hook.getPositions
        );
    }

    function test_visualizePoolAtInitialization() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;

        buy(1);

        SlugVis.visualizeSlugs(
            hook.getNumPDSlugs(), block.timestamp, hook.getCurrentTick(poolKey.toId()), hook.getPositions
        );
    }
}
