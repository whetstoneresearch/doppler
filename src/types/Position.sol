// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bytes32 salt;
}

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
