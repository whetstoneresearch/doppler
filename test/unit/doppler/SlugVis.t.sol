// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { SlugVis } from "../../shared/SlugVis.sol";

contract SlugVisTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    function testSlugVis() public {
        vm.warp(hook.startingTime());

        buy(1 ether);

        SlugVis.visualizeSlugs(hook, "test", block.timestamp);
    }

    function test_visualizePoolAtInitialization() public {
        vm.warp(hook.startingTime());

        buy(1);

        SlugVis.visualizeSlugs(hook, "test", block.timestamp);
    }

    function test_estelle() public {
        vm.warp(hook.startingTime());

        buy(1);

        SlugVis.visualizeSlugs(hook, "epoch1", block.timestamp);

        vm.warp(hook.startingTime() + hook.epochLength());

        sell(1);

        SlugVis.visualizeSlugs(hook, "epoch2", block.timestamp);
    }
}
