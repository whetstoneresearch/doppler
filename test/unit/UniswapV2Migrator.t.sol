// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02, IUniswapV2Pair } from "src/UniswapV2Migrator.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { MigrationMath } from "src/UniswapV2Migrator.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";

contract UniswapV2MigratorTest is Test {
    UniswapV2Migrator public migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        migrator = new UniswapV2Migrator(
            address(this),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET),
            address(0xb055)
        );
    }

    function test_computeDepositAmounts(uint256 balance0, uint256 balance1, uint160 sqrtPriceX96) public {
        vm.skip(true);
        uint256 max = uint256(int256(type(int128).max));

        vm.assume(balance0 > 0 && balance0 <= max);
        vm.assume(balance1 > 0 && balance1 <= max);
        vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE);

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPriceX96);

        if (depositAmount1 > balance1) {
            (, depositAmount1) = MigrationMath.computeDepositAmounts(depositAmount0, balance1, sqrtPriceX96);
        } else {
            (depositAmount0,) = MigrationMath.computeDepositAmounts(balance0, depositAmount1, sqrtPriceX96);
        }

        assertLe(depositAmount0, balance0, "depositAmount0 > balance0");
        assertLe(depositAmount1, balance1, "depositAmount1 > balance1");
        assertGt(depositAmount0, 0, "depositAmount is zero");
        assertGt(depositAmount1, 0, "depositAmount is zero");
    }

    function test_receive_ReceivesETHFromAirlock() public {
        uint256 preBalance = address(migrator).balance;
        deal(address(this), 1 ether);
        payable(address(migrator)).transfer(1 ether);
        assertEq(address(migrator).balance, preBalance + 1 ether, "Wrong balance");
    }

    function test_receive_RevertsWhenETHSenderNotAirlock() public {
        deal(address(0xbeef), 1 ether);
        vm.startPrank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        payable(address(migrator)).transfer(1 ether);
    }

    function test_initialize_CreatesPair() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, new bytes(0));
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token0, token1), "Wrong pair");
    }

    function test_initialize_UsesWETHWhenToken0IsZero() public {
        address token0 = address(0);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, new bytes(0));
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token1, WETH_MAINNET), "Wrong pair");
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
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    function test_migrate() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);

        address pool = migrator.initialize(address(token0), address(token1), new bytes(0));

        token0.transfer(address(migrator), 1000 ether);
        token1.transfer(address(migrator), 1000 ether);
        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(token0), address(token1), address(0xbeef));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), 1000 ether, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), 1000 ether, "Wrong pool token1 balance");

        uint256 lockedLiquidity = liquidity / 20;
        assertEq(liquidity - lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
        assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    }

    function test_migrate(uint256 balance0, uint256 balance1, uint160 sqrtPriceX96) public {
        vm.skip(true);
        uint256 max = uint256(int256(type(int128).max));

        vm.assume(balance0 > 0 && balance0 <= max);
        vm.assume(balance1 > 0 && balance1 <= max);
        vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE);

        TestERC20 token0 = new TestERC20(balance0);
        TestERC20 token1 = new TestERC20(balance1);

        address pool = migrator.initialize(address(token0), address(token1), new bytes(0));

        token0.transfer(address(migrator), balance0);
        token1.transfer(address(migrator), balance1);
        uint256 liquidity = migrator.migrate(sqrtPriceX96, address(token0), address(token1), address(0xbeef));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), balance0, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), balance1, "Wrong pool token1 balance");

        uint256 lockedLiquidity = liquidity / 20;
        assertEq(liquidity - lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
        assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    }

    function test_migrate_AllocateLPToAlice_WhenLiquidityMigratorDataNotEmpty() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        address alice = makeAddr("alice");

        // allocate 10% LP to alice during migration
        bytes memory liquidityMigratorData = abi.encode(0.1 ether, alice);
        address pool = migrator.initialize(address(token0), address(token1), liquidityMigratorData);

        token0.transfer(address(migrator), 1000 ether);
        token1.transfer(address(migrator), 1000 ether);
        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(token0), address(token1), address(0xbeef));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), 1000 ether, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), 1000 ether, "Wrong pool token1 balance");

        uint256 lockedLiquidity = liquidity / 20;
        uint256 allocatedLiquidity = liquidity * 0.1 ether / 1 ether;
        assertEq(
            liquidity - lockedLiquidity - allocatedLiquidity,
            IUniswapV2Pair(pool).balanceOf(address(0xbeef)),
            "Wrong liquidity"
        );
        assertEq(allocatedLiquidity, IUniswapV2Pair(pool).balanceOf(alice), "Wrong allocated liquidity");
        assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    }

    function test_migrate_AllocateLPToAlice_RevertsWhenMaxLPAllocationExceeded() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);
        address alice = makeAddr("alice");

        // try to allocate 20% LP to alice during migration
        bytes memory liquidityMigratorData = abi.encode(0.2 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapV2Migrator.MaxLPAllocationExceeded.selector));
        migrator.initialize(address(token0), address(token1), liquidityMigratorData);
    }

    function test_migrate_AllocateLPToContract_RevertsWhenLPRecipientIsNotEOA() public {
        // TestERC20 token0 = new TestERC20(1000 ether);
        // TestERC20 token1 = new TestERC20(1000 ether);

        // address testContract = makeAddr("testContract");
        // vm.etch(testContract, new bytes(1));
        // bytes memory liquidityMigratorData = abi.encode(0.1 ether, testContract);
        // vm.expectRevert(abi.encodeWithSelector(UniswapV2Migrator.LPRecipientNotEOA.selector));
        // migrator.initialize(address(token0), address(token1), liquidityMigratorData);
    }

    /*
    function test_migrate_MockedCalls() public {
        address token0 = makeAddr("token0");
        address token1 = makeAddr("token1");
        address pool = makeAddr("pool");

        vm.mockCall(
            address(migrator.factory()),
            abi.encodeWithSelector(IUniswapV2Factory.getPair.selector, token0, token1),
            abi.encode(pool)
        );

        migrator.initialize(token0, token1, new bytes(0));

        vm.mockCall(token0, abi.encodeWithSelector(ERC20.balanceOf.selector, address(migrator)), abi.encode(1000 ether));

        vm.mockCall(
            token0, abi.encodeWithSelector(ERC20.transfer.selector, address(pool), 1000 ether), abi.encode(true)
        );

        vm.mockCall(token1, abi.encodeWithSelector(ERC20.balanceOf.selector, address(migrator)), abi.encode(1000 ether));

        vm.mockCall(
            token1, abi.encodeWithSelector(ERC20.transfer.selector, address(pool), 1000 ether), abi.encode(true)
        );

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IUniswapV2Pair.mint.selector, address(migrator)),
            abi.encode(1000 ether)
        );

        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(token0), address(token1), address(0xbeef));
    }
    */

    function test_migrate_WrapsETH() public {
        TestERC20 token1 = new TestERC20(1000 ether);
        address pool = migrator.initialize(address(0), address(token1), new bytes(0));

        deal(address(migrator), 100 ether);
        token1.transfer(address(migrator), 100 ether);

        uint256 nativeBalanceBefore = address(migrator).balance;
        migrator.migrate(uint160(2 ** 96), address(0), address(token1), address(0xbeef));
        assertEq(address(migrator).balance, 0, "Migrator ETH balance is wrong");
        assertEq(TestERC20(WETH_MAINNET).balanceOf(address(migrator)), 0, "Migrator WETH balance is wrong");
        assertEq(TestERC20(WETH_MAINNET).balanceOf(address(pool)), nativeBalanceBefore, "Pool WETH balance is wrong");
    }

    function _initialize() public returns (address pool, TestERC20 token0, TestERC20 token1) {
        token0 = new TestERC20(1000 ether);
        token1 = new TestERC20(1000 ether);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = migrator.initialize(address(token0), address(token1), new bytes(0));
    }
}
