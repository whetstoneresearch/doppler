/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { UniswapV3Initializer, OnlyAirlock } from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";

contract UniswapV3InitializerTest is Test {
    UniswapV3Initializer public initializer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        initializer =
            new UniswapV3Initializer(address(this), IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984));
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(this), "Wrong airlock");
        assertEq(address(initializer.factory()), address(0x1F98431c8aD98523631AE4a59f267346ea31F984), "Wrong factory");
    }

    function test_initialize() public {
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), new address[](0), new uint256[](0));

        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
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

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(OnlyAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }
}
