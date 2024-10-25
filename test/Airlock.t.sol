/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Airlock, FactoryState} from "src/Airlock.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {DopplerFactory} from "src/DopplerFactory.sol";
import {GovernanceFactory} from "src/GovernanceFactory.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Doppler} from "src/Doppler.sol";
import {HookMiner} from "src/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract AirlockTest is Test, Deployers {
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

    /**
     * TODO: Check all the following:
     * - Who is the owner of the token?
     * - Who is the owner of the governance?
     * - Was the v4 pool correctly initialized?
     * - Were all the hook parameters correctly set?
     * -
     */
    function test_Airlock_create() public {
        address numeraire = address(0);
        uint256 totalSupply = 100_000_000_000 ether;
        uint256 startingTime = 1 days;
        uint256 endingTime = 8 days;
        string memory name = "NAME";
        string memory symbol = "SBML";
        address owner = address(0xb0b);
        bytes memory tokenData = abi.encode(0, new address[](0), address(0));
        bytes memory governanceData = new bytes(0);
        bytes memory hookData = new bytes(0);
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        (address token, address governance, address hook) = airlock.create(
            name,
            symbol,
            totalSupply,
            startingTime,
            endingTime,
            numeraire,
            owner,
            address(tokenFactory),
            tokenData,
            address(governanceFactory),
            governanceData,
            address(dopplerFactory),
            hookData,
            recipients,
            amounts
        );

        assertEq(ERC20(token).balanceOf(hook), totalSupply / 2, "Wrong Hook balance");
        assertEq(ERC20(token).balanceOf(address(airlock)), totalSupply / 2, "Wrong Airlock balance");
    }
}
