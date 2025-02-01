// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { Doppler } from "src/Doppler.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { WETH_UNICHAIN_SEPOLIA } from "test/shared/Addresses.sol";
import { DopplerFixtures, DEFAULT_STARTING_TIME } from "test/shared/DopplerFixtures.sol";

/// @dev Tests involving migration of liquidity FROM Doppler to ILiquidityMigrator
contract DopplerMigrateTest is DopplerFixtures {
    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);
        _deployAirlockAndModules();

        swapRouter = new PoolSwapTest(manager);
    }

    /// @dev native Ether migrating from Doppler to v2 gets wrapped as WETH
    function test_dopplerv4_migrate_v2_weth() public {
        address numeraireAddress = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);
        (address asset, PoolKey memory poolKey) = _airlockCreateNative();
        IERC20(asset).approve(address(swapRouter), type(uint256).max);

        // Pool created with native Ether
        assertTrue(poolKey.currency0 == CurrencyLibrary.ADDRESS_ZERO);

        // warp to starting time
        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        // swap to generate fees in native ether
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);

        // mock out an early exit to test migration
        Doppler doppler = Doppler(payable(address(poolKey.hooks)));
        _mockEarlyExit(doppler);

        (address token0, address token1) =
            asset < numeraireAddress ? (asset, WETH_UNICHAIN_SEPOLIA) : (WETH_UNICHAIN_SEPOLIA, asset);
        address v2Pool = uniswapV2Factory.getPair(token0, token1);
        uint256 v2PoolWETHBalanceBefore = IERC20(WETH_UNICHAIN_SEPOLIA).balanceOf(address(v2Pool));

        airlock.migrate(asset);

        // native Ether from Doppler was converted to WETH
        assertEq(address(migrator).balance, 0, "Migrator ETH balance is wrong");
        assertEq(IERC20(WETH_UNICHAIN_SEPOLIA).balanceOf(address(migrator)), 0, "Migrator WETH balance is wrong");
        // TODO: figure out how to assert to exact value
        assertGt(
            IERC20(WETH_UNICHAIN_SEPOLIA).balanceOf(address(v2Pool)),
            v2PoolWETHBalanceBefore,
            "Pool WETH balance is wrong"
        );
    }

    function test_dopplerv4_migrate_all_tokens() public {
        (address asset, PoolKey memory poolKey) = _airlockCreate();
        IERC20(asset).approve(address(swapRouter), type(uint256).max);

        // warp to starting time
        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        // swap to generate fees in native ether
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, true, -0.1e18, ZERO_BYTES);
        Deployers.swap(poolKey, false, -0.1e18, ZERO_BYTES);

        // mock out an early exit to test migration
        Doppler doppler = Doppler(payable(address(poolKey.hooks)));
        _mockEarlyExit(doppler);

        uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(migrator));
        airlock.migrate(asset);

        // all tokens from Doppler were migrated
        assertEq(IERC20(asset).balanceOf(address(migrator), "Migrator token balance is wrong"));
        assertEq(IERC20(asset).balanceOf(address(poolKey.hooks), 0, "Pool token balance is wrong"));
    }
}
