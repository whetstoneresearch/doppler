/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { UniswapV2Locker, PoolAlreadyInitialized, NoBalanceToLock, PoolNotInitialized } from "src/UniswapV2Locker.sol";
import { UNISWAP_V2_FACTORY_MAINNET } from "test/shared/Addresses.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { TestERC20 } from "v4-core/src/test/TestERC20.sol";

contract UniswapV2LockerTest is Test {
    UniswapV2Locker public locker;
    UniswapV2Migrator public migrator;
    IUniswapV2Pair public pool;

    TestERC20 public tokenFoo;
    TestERC20 public tokenBar;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);

        tokenFoo = new TestERC20(1e25);
        tokenBar = new TestERC20(1e25);

        locker = new UniswapV2Locker(
            Airlock(payable(address(this))), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), migrator
        );

        pool = IUniswapV2Pair(
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).createPair(address(tokenFoo), address(tokenBar))
        );
    }

    function test_constructor() public view {
        assertEq(address(locker.airlock()), address(this));
        assertEq(address(locker.factory()), UNISWAP_V2_FACTORY_MAINNET);
        assertEq(address(locker.migrator()), address(migrator));
    }

    function test_receiveAndLock_InitializesPool() public {
        tokenFoo.transfer(address(pool), 1e18);
        tokenBar.transfer(address(pool), 1e18);
        pool.mint(address(locker));
        locker.receiveAndLock(address(pool));
        (,, bool initialized) = locker.getState(address(pool));
        assertEq(initialized, true);
    }

    function test_receiveAndLock_RevertsWhenPoolAlreadyInitialized() public {
        test_receiveAndLock_InitializesPool();
        vm.expectRevert(PoolAlreadyInitialized.selector);
        locker.receiveAndLock(address(pool));
    }

    function test_receiveAndLock_RevertsWhenNoBalanceToLock() public {
        vm.expectRevert(NoBalanceToLock.selector);
        locker.receiveAndLock(address(pool));
    }

    function test_claimFeesAndExit_RevertsWhenPoolNotInitialized() public {
        vm.expectRevert(PoolNotInitialized.selector);
        locker.claimFeesAndExit(address(0xbeef));
    }
}
