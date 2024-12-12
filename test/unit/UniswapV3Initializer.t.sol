/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { UniswapV3Initializer, OnlyAirlock, PoolAlreadyInitialized } from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";

import { WETH_MAINNET, UNISWAP_V3_FACTORY_MAINNET } from "test/shared/Addresses.sol";

contract UniswapV3InitializerTest is Test {
    UniswapV3Initializer public initializer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        initializer = new UniswapV3Initializer(address(this), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(this), "Wrong airlock");
        assertEq(address(initializer.factory()), address(UNISWAP_V3_FACTORY_MAINNET), "Wrong factory");
    }

    function test_initialize() public {
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), new address[](0), new uint256[](0));
        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(-200_040), int24(-167_520))
        );

        assertEq(token.balanceOf(address(initializer)), 0, "Wrong initializer balance");
        // assertEq(token.balanceOf(pool), 1e27, "Wrong pool balance");
        // assertEq(token.balanceOf(address(this)), 1e27, "Wrong this balance");

        uint128 totalLiquidity = IUniswapV3Pool(pool).liquidity();
        assertTrue(totalLiquidity > 0, "Wrong total liquidity");
        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(initializer), int24(-200_040), int24(-167_520)))
        );
        assertEq(liquidity, totalLiquidity, "Wrong liquidity");
    }

    function test_initialize_RevertsIfAlreadyInitialized() public {
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), new address[](0), new uint256[](0));
        token.approve(address(initializer), type(uint256).max);

        initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(-200_040), int24(-167_520))
        );

        vm.expectRevert(PoolAlreadyInitialized.selector);
        initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(-200_040), int24(-167_520))
        );
    }

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(OnlyAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }

    function test_exitLiquidity() public {
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), new address[](0), new uint256[](0));
        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(-200_040), int24(-167_520))
        );

        initializer.exitLiquidity(pool);
    }
}
