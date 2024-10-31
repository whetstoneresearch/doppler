/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DERC20} from "src/DERC20.sol";
import {Doppler} from "src/Doppler.sol";

// mask to slice out the bottom 14 bit of the address
uint160 constant FLAG_MASK = 0x3FFF;

// Maximum number of iterations to find a salt, avoid infinite loops
uint256 constant MAX_LOOP = 100_000;

uint160 constant flags = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
);

struct MineParams {
    address poolManager;
    uint256 numTokensToSell;
    int24 minTick;
    int24 maxTick;
    address airlock;
    string name;
    string symbol;
    uint256 initialSupply;
    address recipient;
    address owner;
    address numeraire;
    uint256 startingTime;
    uint256 endingTime;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 epochLength;
    int24 gamma;
    uint256 numPDSlugs;
}

function mine(address deployer, MineParams memory params) view returns (bytes32, address, address) {
    bool isToken0 = params.numeraire != address(0);

    bytes32 hookInitHash = keccak256(
        abi.encodePacked(
            type(Doppler).creationCode,
            abi.encode(
                params.poolManager,
                params.numTokensToSell,
                params.minimumProceeds,
                params.maximumProceeds,
                params.startingTime,
                params.endingTime,
                params.minTick,
                params.maxTick,
                params.epochLength,
                params.gamma,
                isToken0,
                params.numPDSlugs
            )
        )
    );

    bytes32 tokenInitHash = keccak256(
        abi.encode(
            type(DERC20).creationCode,
            abi.encode(params.name, params.symbol, params.initialSupply, params.recipient, params.owner)
        )
    );

    for (uint256 salt; salt < 1000_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), hookInitHash, deployer);
        address token = computeCreate2Address(bytes32(salt), tokenInitHash, deployer);

        if (
            uint160(hook) & FLAG_MASK == flags && hook.code.length == 0
                && ((isToken0 && token < params.numeraire) || (!isToken0 && token > params.numeraire))
        ) {
            return (bytes32(salt), hook, token);
        }
    }

    revert("AirlockMiner: could not find salt");
}

function computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

contract AirlockMinerTest is Test {
    function test_mine_works() public view {
        address numeraire = address(type(uint160).max / 2);

        (bytes32 salt, address hook, address token) = mine(
            address(this),
            MineParams(
                address(0xbeef),
                1e27,
                int24(-1600),
                int24(1600),
                address(0xdead),
                "Test",
                "TST",
                1e27,
                address(0xb0b),
                address(0xa71ce),
                numeraire,
                1 days,
                7 days,
                1 ether,
                10 ether,
                400 seconds,
                int24(800),
                3
            )
        );

        console.log("salt: %s", uint256(salt));
        console.log("hook: %s", hook);
        console.log("token: %s", token);

        assertTrue(numeraire > token);
    }
}
