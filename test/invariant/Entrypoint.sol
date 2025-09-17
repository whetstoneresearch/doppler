// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

uint256 constant TOTAL_WEIGHTS = 100;

contract Entrypoint {
    bytes4[] internal _selectors;
    mapping(bytes4 => uint256) internal _weights;

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
