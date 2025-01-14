// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { UniswapV2Locker, PoolAlreadyInitialized, NoBalanceToLock, PoolNotInitialized } from "src/UniswapV2Locker.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET } from "test/shared/Addresses.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";

contract UniswapV2LockerTest is Test {
    UniswapV2Locker public locker;
    UniswapV2Migrator public migrator = UniswapV2Migrator(address(0x88888));
    IUniswapV2Pair public pool;

    Airlock public airlock = Airlock(payable(address(0xdeadbeef)));

    TestERC20 public tokenFoo;
    TestERC20 public tokenBar;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);

        tokenFoo = new TestERC20(1e25);
        tokenBar = new TestERC20(1e25);

        locker = new UniswapV2Locker(airlock, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), migrator);

        pool = IUniswapV2Pair(
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).createPair(address(tokenFoo), address(tokenBar))
        );
    }

    function test_constructor() public view {
        assertEq(address(locker.airlock()), address(airlock));
        assertEq(address(locker.factory()), UNISWAP_V2_FACTORY_MAINNET);
        assertEq(address(locker.migrator()), address(migrator));
    }

    function test_receiveAndLock_InitializesPool() public {
        tokenFoo.transfer(address(pool), 100e18);
        tokenBar.transfer(address(pool), 100e18);
        pool.mint(address(locker));
        vm.prank(address(migrator));
        locker.receiveAndLock(address(pool));
        (,, bool initialized) = locker.getState(address(pool));
        assertEq(initialized, true);
    }

    function test_receiveAndLock_RevertsWhenPoolAlreadyInitialized() public {
        test_receiveAndLock_InitializesPool();
        vm.startPrank(address(migrator));
        vm.expectRevert(PoolAlreadyInitialized.selector);
        locker.receiveAndLock(address(pool));
    }

    function test_receiveAndLock_RevertsWhenNoBalanceToLock() public {
        vm.startPrank(address(migrator));
        vm.expectRevert(NoBalanceToLock.selector);
        locker.receiveAndLock(address(pool));
    }

    function getAssetData(
        address
    ) external pure { }

    function owner() external pure { }

    function getAsset(
        address
    ) external pure { }

    function test_claimFeesAndExit() public {
        test_receiveAndLock_InitializesPool();

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
        address timelock = address(0x999);
        vm.mockCall(
            address(airlock),
            abi.encodeWithSelector(this.getAssetData.selector, address(tokenBar)),
            abi.encode(
                address(0),
                timelock,
                address(0),
                address(0),
                address(0),
                address(0),
                address(0),
                uint256(0),
                uint256(0),
                address(0)
            )
        );
        locker.claimFeesAndExit(address(pool));
        assertGt(tokenBar.balanceOf(timelock), 0, "Timelock balance0 is wrong");
        assertGt(tokenFoo.balanceOf(timelock), 0, "Timelock balance1 is wrong");
        assertGt(tokenBar.balanceOf(tokenOwner), 0, "Owner balance0 is wrong");
        assertGt(tokenFoo.balanceOf(tokenOwner), 0, "Owner balance1 is wrong");
        assertEq(pool.balanceOf(address(locker)), 0, "Locker balance is wrong");
    }

    function test_claimFeesAndExit_RevertsWhenPoolNotInitialized() public {
        vm.expectRevert(PoolNotInitialized.selector);
        locker.claimFeesAndExit(address(0xbeef));
    }
}
