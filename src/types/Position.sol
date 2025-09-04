// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Data struct to store Uniswap V4 position information
 * @param tickLower Lower tick of the position
 * @param tickUpper Upper tick of the position
 * @param liquidity Amount of liquidity in the position
 * @param salt Salt to ensure uniqueness of the position
 */
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bytes32 salt;
}

/**
 * @dev Concatenates two arrays of Position structs
 * @param a First array
 * @param b Second array
 * @return c Concatenated array
 */
function concat(Position[] memory a, Position[] memory b) pure returns (Position[] memory) {
    Position[] memory c = new Position[](a.length + b.length);

    uint256 i;

    for (; i != a.length; ++i) {
        c[i] = a[i];
    }

    for (uint256 j; j != b.length; ++j) {
        c[i++] = b[j];
    }

    return c;
}
