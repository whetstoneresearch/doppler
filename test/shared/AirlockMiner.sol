/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
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

struct MineParams {
    address poolManager;
    uint256 numTokensToSell;
    int24 minTick;
    int24 maxTick;
    address airlock;
    string name;
    string symbol;
    uint256 initialSupply;
    address numeraire;
    uint256 startingTime;
    uint256 endingTime;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 epochLength;
    int24 gamma;
    uint256 numPDSlugs;
}

function mine(
    uint256 initialSupply,
    uint256 numTokensToSell,
    address numeraire,
    ITokenFactory tokenFactory,
    bytes memory tokenFactoryData,
    bytes memory tokenCreationCode,
    IGovernanceFactory governanceFactory,
    bytes memory governanceFactoryData,
    IPoolInitializer poolInitializer,
    bytes memory poolInitializerData,
    bytes memory poolCreationCode,
    ILiquidityMigrator liquidityMigrator,
    bytes memory liquidityMigratorData
) view returns (bytes32, address, address) {
    (
        IPoolManager poolManager,
        // uint256 numTokensToSell_
        ,
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

    bytes32 hookInitHash = keccak256(
        abi.encodePacked(
            poolCreationCode,
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

    (string memory name, string memory symbol) = abi.decode(tokenFactoryData, (string, string));

    bytes32 tokenInitHash =
        keccak256(abi.encodePacked(tokenCreationCode, abi.encode("", "", initialSupply, airlock, airlock, address(0))));

    for (uint256 salt; salt < 1_000_000; ++salt) {
        address hook = computeCreate2Address(bytes32(salt), hookInitHash, address(poolInitializer));
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
        address tokenFactory = address(0xb0b);
        address hookFactory = address(0xbeef);
        address numeraire = address(type(uint160).max / 2);

        bytes32 salt;
        address hook;
        address token;

        /*
         = mine(


            tokenFactory,
            hookFactory,
            MineParams(
                address(0xbeef),
                1e27,
                int24(-1600),
                int24(1600),
                address(0xdead),
                "Test",
                "TST",
                1e27,
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

        */

        console.log("salt: %s", uint256(salt));
        console.log("hook: %s", hook);
        console.log("token: %s", token);

        assertTrue(numeraire > token);
    }
}
