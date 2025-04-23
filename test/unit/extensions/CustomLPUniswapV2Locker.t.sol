// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET } from "test/shared/Addresses.sol";
import { Airlock } from "src/Airlock.sol";
import { CustomLPUniswapV2Migrator } from "src/extensions/CustomLPUniswapV2Migrator.sol";
import { CustomLPUniswapV2Locker } from "src/extensions/CustomLPUniswapV2Locker.sol";
import { IUniswapV2Locker } from "src/interfaces/IUniswapV2Locker.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";

contract UniswapV2LockerTest is Test {
    CustomLPUniswapV2Locker public locker;
    CustomLPUniswapV2Migrator public migrator = CustomLPUniswapV2Migrator(payable(address(0x88888)));
    IUniswapV2Pair public pool;

    Airlock public airlock = Airlock(payable(address(0xdeadbeef)));

    TestERC20 public tokenFoo;
    TestERC20 public tokenBar;

    address aliceRecipient = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);

        tokenFoo = new TestERC20(1e25);
        tokenBar = new TestERC20(1e25);

        locker = new CustomLPUniswapV2Locker(
            address(airlock), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), migrator, address(0xb055)
        );

        pool = IUniswapV2Pair(
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).createPair(address(tokenFoo), address(tokenBar))
        );
    }

    function test_constructor() public view {
        assertEq(address(locker.factory()), UNISWAP_V2_FACTORY_MAINNET);
        assertEq(address(locker.migrator()), address(migrator));
    }

    function test_receiveAndLock_WithLockUpPeriod_InitializesPool() public {
        tokenFoo.transfer(address(pool), 100e18);
        tokenBar.transfer(address(pool), 100e18);
        pool.mint(address(locker));
        vm.prank(address(migrator));
        locker.receiveAndLock(address(pool), aliceRecipient, 30 days);
    }

    function test_receiveAndLock_RevertsWhenPoolAlreadyInitialized() public {
        test_receiveAndLock_WithLockUpPeriod_InitializesPool();
        vm.startPrank(address(migrator));
        vm.expectRevert(IUniswapV2Locker.PoolAlreadyInitialized.selector);
        locker.receiveAndLock(address(pool), aliceRecipient, 30 days);
    }

    function test_receiveAndLock_RevertsWhenNoBalanceToLock() public {
        vm.startPrank(address(migrator));
        vm.expectRevert(IUniswapV2Locker.NoBalanceToLock.selector);
        locker.receiveAndLock(address(pool), aliceRecipient, 30 days);
    }

    function test_receiveAndLock_RevertsWhenLessThanMinLockPeriod() public {
        vm.startPrank(address(migrator));
        vm.expectRevert(CustomLPUniswapV2Locker.LessThanMinLockPeriod.selector);
        locker.receiveAndLock(address(pool), aliceRecipient, 29 days);
    }

    function owner() external pure { }

    function getAsset(
        address
    ) external pure { }

    function test_claimFeesAndExit_RevertsWhenMinUnlockDateNotReached() public {
        test_receiveAndLock_WithLockUpPeriod_InitializesPool();
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(IUniswapV2Locker.MinUnlockDateNotReached.selector);
        locker.claimFeesAndExit(address(pool));
    }

    function test_claimFeesAndExit() public {
        test_receiveAndLock_WithLockUpPeriod_InitializesPool();

        address[] memory path = new address[](2);
        path[0] = address(tokenFoo);
        path[1] = address(tokenBar);

        tokenFoo.approve(UNISWAP_V2_ROUTER_MAINNET, 1 ether);
        IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET).swapExactTokensForTokens(
            1 ether, 0, path, address(this), block.timestamp
        );

        address tokenOwner = address(0xb0b);
        vm.mockCall(address(airlock), abi.encodeWithSelector(this.owner.selector), abi.encode(tokenOwner));
        vm.mockCall(
            address(migrator),
            abi.encodeWithSelector(this.getAsset.selector, address(pool)),
            abi.encode(address(tokenBar))
        );

        vm.warp(block.timestamp + 30 days);

        locker.claimFeesAndExit(address(pool));
        assertGt(tokenBar.balanceOf(aliceRecipient), 0, "alice balance0 is wrong");
        assertGt(tokenFoo.balanceOf(aliceRecipient), 0, "alice balance1 is wrong");
        assertGt(tokenBar.balanceOf(address(0xb055)), 0, "Owner balance0 is wrong");
        assertGt(tokenFoo.balanceOf(address(0xb055)), 0, "Owner balance1 is wrong");
        assertEq(pool.balanceOf(address(locker)), 0, "Locker balance is wrong");
    }

    function test_claimFeesAndExit_RevertsWhenPoolNotInitialized() public {
        vm.expectRevert(IUniswapV2Locker.PoolNotInitialized.selector);
        vm.prank(address(0xb055));
        locker.claimFeesAndExit(address(0xbeef));
    }
}
