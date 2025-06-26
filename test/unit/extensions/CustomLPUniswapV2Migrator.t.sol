// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ICustomLPUniswapV2Migrator } from "src/extensions/interfaces/ICustomLPUniswapV2Migrator.sol";
import { CustomLPUniswapV2Migrator } from "src/extensions/CustomLPUniswapV2Migrator.sol";
import { IUniswapV2Factory, IUniswapV2Router02, IUniswapV2Pair } from "src/UniswapV2Migrator.sol";
import { MigrationMath } from "src/UniswapV2Migrator.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";

contract CustomLPUniswapV2MigratorTest is Test {
    CustomLPUniswapV2Migrator public migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        migrator = new CustomLPUniswapV2Migrator(
            address(this),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET),
            address(0xb055)
        );
    }

    function test_migrate_CustomLPToEOA_WhenLiquidityMigratorDataNotEmpty() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        // allocate 3% LP to alice during migration
        uint256 customLPWad = 0.03 ether;
        uint32 lockUpPeriod = 30 days;
        address alice = makeAddr("alice");

        bytes memory liquidityMigratorData = abi.encode(customLPWad, alice, lockUpPeriod);
        address pool = migrator.initialize(address(token0), address(token1), liquidityMigratorData);

        (uint32 actualLockUpPeriod, uint64 actualCustomLPWad, address actualCustomLPRecipient) =
            migrator.customLPStates(pool);
        assertEq(actualCustomLPWad, customLPWad, "Wrong custom LP wad");
        assertEq(actualCustomLPRecipient, alice, "Wrong custom LP recipient");
        assertEq(actualLockUpPeriod, lockUpPeriod, "Wrong lock up period");

        token0.transfer(address(migrator), 1000 ether);
        token1.transfer(address(migrator), 1000 ether);
        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(token0), address(token1), address(0xbeef));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), 1000 ether, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), 1000 ether, "Wrong pool token1 balance");

        uint256 customLockedLiquidity = liquidity * customLPWad / 1 ether;
        assertEq(liquidity - customLockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
        assertEq(0, IUniswapV2Pair(pool).balanceOf(alice), "Wrong custom locked liquidity");
        assertEq(
            customLockedLiquidity,
            IUniswapV2Pair(pool).balanceOf(address(migrator.CUSTOM_LP_LOCKER())),
            "Wrong custom locked liquidity"
        );
    }

    function test_migrate_CustomLPToEOA_RevertsWhenMaxLPAllocationExceeded() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        // try to allocate 20% LP to alice during migration
        uint256 customLPWad = 0.2 ether;
        uint32 lockUpPeriod = 30 days;
        address alice = makeAddr("alice");

        bytes memory liquidityMigratorData = abi.encode(customLPWad, alice, lockUpPeriod);
        vm.expectRevert(abi.encodeWithSelector(ICustomLPUniswapV2Migrator.MaxCustomLPWadExceeded.selector));
        migrator.initialize(address(token0), address(token1), liquidityMigratorData);
    }

    function test_migrate_CustomLPToSmartContract_RevertsWhenLPRecipientIsNotEOA() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        uint256 customLPWad = 0.01 ether;
        uint32 lockUpPeriod = 30 days;
        address testContract = makeAddr("testContract");
        vm.etch(testContract, new bytes(1));

        bytes memory liquidityMigratorData = abi.encode(customLPWad, testContract, lockUpPeriod);
        vm.expectRevert(abi.encodeWithSelector(ICustomLPUniswapV2Migrator.RecipientNotEOA.selector));
        migrator.initialize(address(token0), address(token1), liquidityMigratorData);
    }

    function test_migrate_CustomLPToSmartContract_RevertsWhenLessThanMinLockPeriod() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        uint256 customLPWad = 0.03 ether;
        uint32 lockUpPeriod = 29 days;
        address alice = makeAddr("alice");

        bytes memory liquidityMigratorData = abi.encode(customLPWad, alice, lockUpPeriod);
        vm.expectRevert(abi.encodeWithSelector(ICustomLPUniswapV2Migrator.LessThanMinLockPeriod.selector));
        migrator.initialize(address(token0), address(token1), liquidityMigratorData);
    }
}
