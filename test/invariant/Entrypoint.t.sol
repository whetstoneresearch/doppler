// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Entrypoint, TOTAL_WEIGHTS } from "test/invariant/Entrypoint.sol";

contract EntrypointTest is Test {
    Entrypoint public entrypoint;

    mapping(bytes4 => uint256) public results;

    function setUp() public {
        entrypoint = new Entrypoint();
    }

    function test_entrypoint(
        uint256 rng
    ) public {
        vm.assume(rng > 0);
        uint256 seed = type(uint256).max % rng;

        bytes4[] memory selectors = new bytes4[](3);
        uint256[] memory weights = new uint256[](3);

        selectors[0] = bytes4(hex"beefbeef");
        selectors[1] = bytes4(hex"cafecafe");
        selectors[2] = bytes4(hex"deadbeef");

        weights[0] = 50;
        weights[1] = 25;
        weights[2] = 25;

        entrypoint.setSelectorWeights(selectors, weights);

        uint256 runs = 1000;

        for (uint256 i; i < runs; i++) {
            bytes4 selector = entrypoint.entrypoint(seed + i);
            results[selector] += 1;
        }

        assertEq(results[bytes4(hex"beefbeef")], weights[0] * runs / TOTAL_WEIGHTS, "beefbeef");
        assertEq(results[bytes4(hex"cafecafe")], weights[1] * runs / TOTAL_WEIGHTS, "cafecafe");
        assertEq(results[bytes4(hex"deadbeef")], weights[2] * runs / TOTAL_WEIGHTS, "deadbeef");
    }
}
