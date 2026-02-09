// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { IUniswapV2Factory, IUniswapV2Pair, UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";
import { MigrationMath } from "src/migrators/UniswapV2MigratorSplit.sol";
import { UNISWAP_V2_FACTORY_MAINNET, UNISWAP_V2_ROUTER_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract UniswapV2MigratorTest is Test {
    UniswapV2MigratorSplit public migrator;
    TopUpDistributor public topUpDistributor;

    address airlockOwner = makeAddr("AIRLOCK_OWNER");

    function owner() external returns (address) {
        return airlockOwner;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);
        topUpDistributor = new TopUpDistributor(address(this));
        migrator = new UniswapV2MigratorSplit(
            address(this), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), topUpDistributor, WETH_MAINNET
        );
        vm.prank(airlockOwner);
        topUpDistributor.setPullUp(address(migrator), true);
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

    /* ----------------------------------------------------------------------- */
    /*                                receive()                                */
    /* ----------------------------------------------------------------------- */

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

    /* -------------------------------------------------------------------------- */
    /*                                initialize()                                */
    /* -------------------------------------------------------------------------- */

    function test_initialize_CreatesPair() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, _getData());
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token0, token1), "Wrong pair");
    }

    function test_initialize_UsesWETHWhenNumeraireIsZero() public {
        address asset = address(0x2222);
        address numeraire = address(0);
        address pair = migrator.initialize(asset, numeraire, _getData());
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(asset, WETH_MAINNET), "Wrong pair");
    }

    function test_initialize_DoesNotFailWhenPairIsAlreadyCreated() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).createPair(token0, token1);
        address pair = migrator.initialize(token0, token1, _getData());
        assertEq(pair, IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET).getPair(token0, token1), "Wrong pair");
    }

    /* ----------------------------------------------------------------------- */
    /*                                migrate()                                */
    /* ----------------------------------------------------------------------- */

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    function test_migrate() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);

        address pool = migrator.initialize(address(token0), address(token1), _getData());

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

    function test_migrate_KeepsCorrectPrice() public {
        TestERC20 asset = new TestERC20(131_261_409_265_385_327_997_940);
        TestERC20 numeraire = new TestERC20(16_622_742_685_037);

        uint160 sqrtPriceX96 = 3_893_493_510_706_508_098_175_185;

        address pool = migrator.initialize(address(asset), address(numeraire), _getData());

        asset.transfer(address(migrator), 13_126_140_926_538_532_799_794);
        numeraire.transfer(address(migrator), 16_622_742_685_037);

        (TestERC20 token0, TestERC20 token1) =
            address(asset) < address(numeraire) ? (asset, numeraire) : (numeraire, asset);
        migrator.migrate(sqrtPriceX96, address(token0), address(token1), address(0xbeef));
        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
        uint256 price = uint256(reserve1) * 2 ** 192 / uint256(reserve0);
        assertApproxEqRel(price, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 0.00000001e18);
    }

    function test_migrate(uint256 balance0, uint256 balance1, uint160 sqrtPriceX96) public {
        vm.skip(true);
        uint256 max = uint256(int256(type(int128).max));

        vm.assume(balance0 > 0 && balance0 <= max);
        vm.assume(balance1 > 0 && balance1 <= max);
        vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE);

        TestERC20 token0 = new TestERC20(balance0);
        TestERC20 token1 = new TestERC20(balance1);

        address pool = migrator.initialize(address(token0), address(token1), _getData());

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

        migrator.initialize(token0, token1, _getData());

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
        TestERC20 asset = new TestERC20(1000 ether);
        address pool = migrator.initialize(address(asset), address(0), _getData());

        deal(address(migrator), 100 ether);
        asset.transfer(address(migrator), 100 ether);

        uint256 nativeBalanceBefore = address(migrator).balance;

        migrator.migrate(uint160(2 ** 96), address(0), address(asset), address(0xbeef));
        assertEq(address(migrator).balance, 0, "Migrator ETH balance is wrong");
        assertEq(TestERC20(WETH_MAINNET).balanceOf(address(migrator)), 0, "Migrator WETH balance is wrong");
        assertEq(TestERC20(WETH_MAINNET).balanceOf(address(pool)), nativeBalanceBefore, "Pool WETH balance is wrong");
    }

    function test_migrate_WithNonZeroShare() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);

        // Ensure token0 < token1 for proper ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        address splitRecipient = address(0xdead);
        uint256 share = 0.1e18; // 10% share

        address pool = migrator.initialize(address(token0), address(token1), abi.encode(splitRecipient, share));

        uint256 amount0 = 1000 ether;
        uint256 amount1 = 1000 ether;

        token0.transfer(address(migrator), amount0);
        token1.transfer(address(migrator), amount1);

        // token0 is asset (isToken0 = true), so token1 is numeraire
        // The share is taken from the numeraire (token1)
        uint256 expectedSplitAmount = amount1 * share / 1e18; // 100 ether
        uint256 balance1AfterSplit = amount1 - expectedSplitAmount; // 900 ether

        uint256 splitRecipientBalanceBefore = token1.balanceOf(splitRecipient);
        uint256 lpRecipientToken0BalanceBefore = token0.balanceOf(address(0xbeef));

        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(token0), address(token1), address(0xbeef));

        // Check split recipient received the correct amount of numeraire (token1)
        assertEq(
            token1.balanceOf(splitRecipient),
            splitRecipientBalanceBefore + expectedSplitAmount,
            "Split recipient didn't receive correct amount"
        );

        // Check migrator has no leftover tokens
        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        // With sqrtPriceX96 = 2**96 (price = 1:1) and balance1AfterSplit = 900 ether,
        // the deposit amounts are limited to 900 ether each to maintain price ratio
        // The remaining token0 (100 ether) is sent as dust to the LP recipient
        uint256 expectedPoolBalance = balance1AfterSplit; // 900 ether each
        assertEq(token0.balanceOf(pool), expectedPoolBalance, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), expectedPoolBalance, "Wrong pool token1 balance");

        // Check the LP recipient received the dust (excess token0)
        uint256 expectedDust = amount0 - expectedPoolBalance; // 100 ether
        assertEq(
            token0.balanceOf(address(0xbeef)),
            lpRecipientToken0BalanceBefore + expectedDust,
            "LP recipient didn't receive dust"
        );

        // Check liquidity distribution
        uint256 lockedLiquidity = liquidity / 20;
        assertEq(liquidity - lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
        assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    }

    function test_migrate_WithNonZeroShareAndETHNumeraire() public {
        TestERC20 asset = new TestERC20(1000 ether);

        address splitRecipient = address(0xdead);
        uint256 share = 0.1e18; // 10% share

        // asset is the token, numeraire is ETH (address(0))
        // In initialize, when numeraire is address(0), token0 becomes WETH
        // isToken0 = (asset < numeraire) which is always false since address(0) is smallest
        address pool = migrator.initialize(address(asset), address(0), abi.encode(splitRecipient, share));

        uint256 assetAmount = 1000 ether;
        uint256 ethAmount = 100 ether;

        asset.transfer(address(migrator), assetAmount);
        deal(address(migrator), ethAmount);

        // numeraire is ETH (which becomes WETH internally)
        // isToken0 = false means asset is NOT token0, so WETH is token0
        // The share is taken from the numeraire (WETH/ETH which is token0 in the split config)
        uint256 expectedSplitAmount = ethAmount * share / 1e18; // 10 ether
        uint256 ethBalanceAfterSplit = ethAmount - expectedSplitAmount; // 90 ether

        uint256 splitRecipientWETHBalanceBefore = TestERC20(WETH_MAINNET).balanceOf(splitRecipient);
        uint256 lpRecipientAssetBalanceBefore = asset.balanceOf(address(0xbeef));

        // Pass address(0) as first arg (token0) since the migrate function expects ETH there
        uint256 liquidity = migrator.migrate(uint160(2 ** 96), address(0), address(asset), address(0xbeef));

        // Check split recipient received the correct amount of WETH (not raw ETH)
        assertEq(
            TestERC20(WETH_MAINNET).balanceOf(splitRecipient),
            splitRecipientWETHBalanceBefore + expectedSplitAmount,
            "Split recipient didn't receive correct WETH amount"
        );

        // Check migrator has no leftover tokens or ETH
        assertEq(asset.balanceOf(address(migrator)), 0, "Wrong migrator asset balance");
        assertEq(address(migrator).balance, 0, "Wrong migrator ETH balance");
        assertEq(TestERC20(WETH_MAINNET).balanceOf(address(migrator)), 0, "Wrong migrator WETH balance");

        // With sqrtPriceX96 = 2**96 (price = 1:1) and ethBalanceAfterSplit = 90 ether,
        // the deposit amounts are limited to 90 ether each to maintain price ratio
        // Depending on token ordering, check the pool balances
        (address token0, address token1) =
            address(asset) < WETH_MAINNET ? (address(asset), WETH_MAINNET) : (WETH_MAINNET, address(asset));

        uint256 poolToken0Balance = TestERC20(token0).balanceOf(pool);
        uint256 poolToken1Balance = TestERC20(token1).balanceOf(pool);

        // Pool should have equal amounts of both tokens (90 ether each)
        assertEq(poolToken0Balance, ethBalanceAfterSplit, "Wrong pool token0 balance");
        assertEq(poolToken1Balance, ethBalanceAfterSplit, "Wrong pool token1 balance");

        // Check the LP recipient received the dust (excess asset)
        uint256 expectedDust = assetAmount - ethBalanceAfterSplit; // 910 ether
        assertEq(
            asset.balanceOf(address(0xbeef)),
            lpRecipientAssetBalanceBefore + expectedDust,
            "LP recipient didn't receive dust"
        );

        // Check liquidity distribution
        uint256 lockedLiquidity = liquidity / 20;
        assertEq(liquidity - lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
        assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    }

    /* --------------------------------------------------------------------- */
    /*                                Helpers                                */
    /* --------------------------------------------------------------------- */

    function _initialize() public returns (address pool, TestERC20 token0, TestERC20 token1) {
        token0 = new TestERC20(1000 ether);
        token1 = new TestERC20(1000 ether);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = migrator.initialize(address(token0), address(token1), _getData());
    }

    function _getData() internal view returns (bytes memory data) {
        data = abi.encode(address(0xbeef), 0);
    }
}
