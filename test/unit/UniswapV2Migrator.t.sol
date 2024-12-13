/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import {
    UniswapV2Migrator,
    IUniswapV2Factory,
    IUniswapV2Router02,
    SenderNotAirlock,
    IUniswapV2Pair
} from "src/UniswapV2Migrator.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";
import { TestERC20 } from "v4-core/src/test/TestERC20.sol";

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

    function test_initialize_UsesWETHWhenToken0IsZero() public {
        address token0 = address(0);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, new bytes(0));
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token1, WETH_MAINNET), "Wrong pair");
        assertEq(pair, migrator.getPool(token1, WETH_MAINNET), "Wrong pair");
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

    function test_migrate() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);

        address pool = migrator.initialize(address(token0), address(token1), new bytes(0));

        token0.transfer(address(migrator), 1000 ether);
        token1.transfer(address(migrator), 1000 ether);
        uint256 liquidity =
            migrator.migrate(address(token0), 1000 ether, address(token1), 1000 ether, address(0xbeef), new bytes(0));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), 1000 ether, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), 1000 ether, "Wrong pool token1 balance");

        assertEq(liquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
    }
}
