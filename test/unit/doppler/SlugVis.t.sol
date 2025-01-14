// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { PoolIdLibrary } from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { SlugVis } from "test/shared/SlugVis.sol";

contract SlugVisTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    function testSlugVis() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;

        buy(1 ether);

        SlugVis.visualizeSlugs(hook, poolKey.toId(), "test", block.timestamp);
    }

    function test_visualizePoolAtInitialization() public {
        vm.warp(hook.getStartingTime());

        PoolKey memory poolKey = key;

        buy(1);

        SlugVis.visualizeSlugs(hook, poolKey.toId(), "test", block.timestamp);
    }
}
