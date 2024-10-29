/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";
import {Airlock, ModuleState} from "src/Airlock.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {DopplerFactory} from "src/DopplerFactory.sol";
import {GovernanceFactory} from "src/GovernanceFactory.sol";
import {UniswapV2Migrator} from "src/UniswapV2Migrator.sol";

contract AirlockTest is Test, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    DopplerFactory dopplerFactory;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator migrator;

    function setUp() public {
        deployFreshManager();
        airlock = new Airlock(manager);
        tokenFactory = new TokenFactory();
        dopplerFactory = new DopplerFactory();
        governanceFactory = new GovernanceFactory();

        airlock.setModuleState(address(tokenFactory), ModuleState.TokenFactory);
        airlock.setModuleState(address(dopplerFactory), ModuleState.HookFactory);
        airlock.setModuleState(address(governanceFactory), ModuleState.GovernanceFactory);
        airlock.setModuleState(address(migrator), ModuleState.Migrator);
    }

    function test_setModuleState_SetsState() public {
        airlock.setModuleState(address(0xbeef), ModuleState.TokenFactory);
        assertEq(uint8(airlock.getModuleState(address(0xbeef))), uint8(ModuleState.TokenFactory));
    }
}
