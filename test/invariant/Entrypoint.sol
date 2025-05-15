// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

uint256 constant TOTAL_WEIGHTS = 100;

contract Entrypoint {
    bytes4[] public _selectors;
    mapping(bytes4 => uint256) public _weights;

    function setSelectorWeights(bytes4[] memory selectors, uint256[] memory weights) external {
        require(selectors.length == weights.length, "Arrays mismatch");
        uint256 totalWeights = 0;

        for (uint256 i; i < selectors.length; i++) {
            _weights[selectors[i]] = weights[i];
            _selectors.push(selectors[i]);
            totalWeights += weights[i];
        }

        require(totalWeights == TOTAL_WEIGHTS, "Total weights not TOTAL_WEIGHTS");
    }

    function entrypoint(
        uint256 seed
    ) public view returns (bytes4 selector) {
        uint256 value = seed % TOTAL_WEIGHTS;
        uint256 range;

        for (uint256 i; i < _selectors.length; i++) {
            range += _weights[_selectors[i]];

            if (value < range) {
                selector = _selectors[i];
                break;
            }
        }
    }
}

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
