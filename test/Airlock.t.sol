/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {console} from "forge-std/console.sol";
import {Airlock, FactoryState} from "src/Airlock.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {DopplerFactory} from "src/DopplerFactory.sol";
import {GovernanceFactory} from "src/GovernanceFactory.sol";
import {Doppler} from "src/Doppler.sol";
import {HookMiner} from "src/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract AirlockTest is Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    DopplerFactory dopplerFactory;
    GovernanceFactory governanceFactory;

    function setUp() public {
        deployFreshManager();
        airlock = new Airlock(manager);
        tokenFactory = new TokenFactory();
        dopplerFactory = new DopplerFactory();
        governanceFactory = new GovernanceFactory();

        airlock.setFactoryState(address(tokenFactory), FactoryState.TokenFactory);
        airlock.setFactoryState(address(dopplerFactory), FactoryState.HookFactory);
        airlock.setFactoryState(address(governanceFactory), FactoryState.GovernanceFactory);
    }

    uint256 numTokensToSell;
    uint256 startingTime;
    uint256 endingTime;
    int24 startingTick;
    int24 endingTick;
    uint256 epochLength;
    uint256 gamma;
    bool isToken0;

    bytes public tokenData =
        abi.encode(numTokensToSell, startingTime, endingTime, startingTick, endingTick, epochLength, gamma, isToken0);

    function test_Airlock_create() public {
        (address token, address governance, address hook) = airlock.create(
            address(tokenFactory),
            "NAME",
            "SYMBOL",
            1_000_000 ether,
            address(0xb0b),
            abi.encode(0, new address[](0), address(0)),
            address(governanceFactory),
            new bytes(0), // No extra data for now
            address(dopplerFactory),
            abi.encode(
                100_000e18,
                1_500, // 500 seconds from now
                1_500 + 86_400, // 1 day from the start time
                -100_000,
                -200_000,
                50,
                1_000,
                true
            ),
            1_000_000 ether,
            address(0xbeef),
            new address[](0),
            new uint256[](0)
        );
    }
}
