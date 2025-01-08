/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { UniswapV2Locker, NoBalanceToLock } from "src/UniswapV2Locker.sol";
import { UNISWAP_V2_FACTORY_MAINNET } from "test/shared/Addresses.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";

contract UniswapV2LockerTest is Test {
    UniswapV2Locker public locker;
    UniswapV2Migrator public migrator;

    function setUp() public {
        locker = new UniswapV2Locker(
            Airlock(payable(address(this))), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), migrator
        );
    }

    function test_receiveAndLock_RevertsWhenNoBalanceToLock() public {
        address pool = address(0x123);
        vm.mockCall(pool, abi.encodeWithSelector(IUniswapV2Pair.balanceOf.selector, address(locker)), abi.encode(0));
        vm.expectRevert(NoBalanceToLock.selector);
        locker.receiveAndLock(pool);
    }
}
