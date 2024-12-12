/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02, SenderNotAirlock } from "src/UniswapV2Migrator.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET } from "test/shared/Addresses.sol";

contract UniswapV2MigratorTest is Test {
    UniswapV2Migrator public migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        migrator = new UniswapV2Migrator(
            address(this), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET)
        );
    }

    function test_initialize_CreatesPair() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, new bytes(0));
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token0, token1), "Wrong pair");
        assertEq(pair, migrator.getPool(token0, token1), "Wrong pair");
    }

    function test_initialize_DoesNotFailWhenPairIsAlreadyCreated() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).createPair(token0, token1);
        address pair = migrator.initialize(token0, token1, new bytes(0));
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token0, token1), "Wrong pair");
    }

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(address(0x1111), 0, address(0x2222), 0, address(0), new bytes(0));
    }
}
