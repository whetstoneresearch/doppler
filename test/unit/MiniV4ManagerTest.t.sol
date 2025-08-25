// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { MiniV4Manager, CallerNotPoolManager } from "src/MiniV4Manager.sol";

contract MiniV4ManagerImplementation is MiniV4Manager {
    constructor(
        IPoolManager poolManager_
    ) MiniV4Manager(poolManager_) { }
}

contract MiniV4ManagerTest is Deployers {
    MiniV4Manager public mini;

    function setUp() public {
        deployFreshManager();
        mini = new MiniV4ManagerImplementation(manager);
    }

    function test_constructor() public view {
        assertEq(address(mini.poolManager()), address(manager), "Wrong PoolManager address");
    }

    function test_unlockCallback_RevertsIfSenderNotPoolManager() public {
        vm.expectRevert(CallerNotPoolManager.selector);
        mini.unlockCallback(new bytes(0));
    }
}
