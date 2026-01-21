// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { LibString } from "@solmate/utils/LibString.sol";

library ChainIds {
    uint256 constant ETH_MAINNET = 1;
    uint256 constant UNICHAIN_MAINNET = 130;
    uint256 constant UNICHAIN_SEPOLIA = 1301;
    uint256 constant INK_MAINNET = 57_073;
    uint256 constant BASE_MAINNET = 8453;
    uint256 constant BASE_SEPOLIA = 84_532;
    uint256 constant MONAD_MAINNET = 143;
    uint256 constant MONAD_TESTNET = 10_143;
}

using LibString for uint256;

function checkChainId(uint256 expected) view {
    require(
        block.chainid == expected,
        string.concat("Expected chainId ", expected.toString(), " but actual is ", block.chainid.toString())
    );
}
