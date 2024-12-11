/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { UniswapV3Initializer, IUniswapV3Factory, OnlyAirlock } from "src/UniswapV3Initializer.sol";

contract UniswapV3InitializerTest is Test {
    UniswapV3Initializer public initializer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        initializer =
            new UniswapV3Initializer(address(0xbeef), IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984));
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(0xbeef), "Wrong airlock");
        assertEq(address(initializer.factory()), address(0x1F98431c8aD98523631AE4a59f267346ea31F984), "Wrong factory");
    }

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.expectRevert(OnlyAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }
}
