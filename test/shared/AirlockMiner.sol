/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { DERC20 } from "src/DERC20.sol";
import { Doppler, IPoolManager } from "src/Doppler.sol";

// mask to slice out the bottom 14 bit of the address
uint160 constant FLAG_MASK = 0x3FFF;

// Maximum number of iterations to find a salt, avoid infinite loops
uint256 constant MAX_LOOP = 100_000;

uint160 constant flags = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
);

function mineV4(
    uint256 initialSupply,
    address numeraire,
    ITokenFactory tokenFactory,
    bytes memory tokenFactoryData,
    IPoolInitializer poolInitializer,
    bytes memory poolInitializerData
) view returns (bytes32, address, address) {
    (
        IPoolManager poolManager,
        uint256 numTokensToSell,
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        uint256 startingTime,
        uint256 endingTime,
        int24 startingTick,
        int24 endingTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        uint256 numPDSlugs,
        address airlock
    ) = abi.decode(
        poolInitializerData,
        (
            IPoolManager,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            int24,
            int24,
            uint256,
            int24,
            bool,
            uint256,
            address
        )
    );

    isToken0 = numeraire != address(0);

    bytes32 dopplerInitHash = keccak256(
        abi.encodePacked(
            type(Doppler).creationCode,
            abi.encode(
                poolManager,
                numTokensToSell,
                minimumProceeds,
                maximumProceeds,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0,
                numPDSlugs,
                airlock
            )
        )
    );

    (
        string memory name,
        string memory symbol,
        uint256 yearlyMintCap,
        address[] memory recipients,
        uint256[] memory amounts
    ) = abi.decode(tokenFactoryData, (string, string, uint256, address[], uint256[]));

    bytes32 tokenInitHash = keccak256(
        abi.encodePacked(
            type(DERC20).creationCode,
            abi.encode(name, symbol, initialSupply, airlock, airlock, yearlyMintCap, recipients, amounts)
        )
    );

    for (uint256 salt; salt < 1000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), dopplerInitHash, address(poolInitializer));
        address asset = computeCreate2Address(bytes32(salt), tokenInitHash, address(tokenFactory));

        if (
            uint160(hook) & FLAG_MASK == flags && hook.code.length == 0
                && ((isToken0 && asset < numeraire) || (!isToken0 && asset > numeraire))
        ) {
            return (bytes32(salt), hook, asset);
        }
    }

    revert("AirlockMiner: could not find salt");
}

function computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

contract AirlockMinerTest is Test {
    function test_mine_works() public view {
        (bytes32 salt, address hook, address token) = mineV4(
            1e27,
            address(0),
            ITokenFactory(address(0xfac)),
            abi.encode("Test", "TST", 1e27, new address[](0), new uint256[](0)),
            IPoolInitializer(address(0x9007)),
            abi.encode(address(0x44444), 0, 0, 0, 0, 0, int24(0), int24(0), 0, int24(0), false, 0, address(this))
        );

        console.log("salt: %s", uint256(salt));
        console.log("hook: %s", hook);
        console.log("token: %s", token);

        // assertTrue(address(0) > token);
    }
}
