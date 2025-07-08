/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { WETH } from "@solmate/tokens/WETH.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import {
    LockableUniswapV3Initializer,
    PoolAlreadyInitialized,
    PoolAlreadyExited,
    OnlyPool,
    CallbackData,
    InitData
} from "src/LockableUniswapV3Initializer.sol";
import { BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { DERC20 } from "src/DERC20.sol";

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = 167_520 + 12_000;
int24 constant DEFAULT_TARGET_TICK_DELTA = 12_000;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;
uint16 constant DEFAULT_NUM_POSITIONS = 10;

contract LockableUniswapV3InitializerTest is Test {
    LockableUniswapV3Initializer public initializer;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"), 28_099_832);
        initializer = new LockableUniswapV3Initializer(
            address(this), IUniswapV3Factory(0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24)
        );
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(this), "Wrong airlock");
        assertEq(address(initializer.factory()), address(0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24), "Wrong factory");
    }

    function test_initialize_success() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1), shares: 0.1 ether });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x2), shares: 0.4 ether });
        beneficiaries[2] = BeneficiaryData({ beneficiary: address(0x3), shares: 0.5 ether });

        address pool = initializer.initialize(
            address(token),
            address(0x4200000000000000000000000000000000000006),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: beneficiaries
                })
            )
        );

        assertEq(token.balanceOf(address(initializer)), 0, "Wrong initializer balance");

        uint128 totalLiquidity = IUniswapV3Pool(pool).liquidity();
        assertTrue(totalLiquidity > 0, "Wrong total liquidity");

        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(initializer), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK)))
        );
        assertEq(liquidity, totalLiquidity, "Wrong liquidity");
    }

    function test_initialize_RevertsIfAlreadyInitialized() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        initializer.initialize(
            address(token),
            address(0x4200000000000000000000000000000000000006),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );

        vm.expectRevert(PoolAlreadyInitialized.selector);
        initializer.initialize(
            address(token),
            address(0x4200000000000000000000000000000000000006),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }

    /*
    function test_exitLiquidity() public returns (address pool) {
        bool isToken0;
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(token) < address(0x4200000000000000000000000000000000000006)) {
            token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }

        isToken0 = address(token) < address(0x4200000000000000000000000000000000000006);
        token.approve(address(initializer), type(uint256).max);

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;
        int24 targetTick = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_LOWER_TICK;

        pool = initializer.initialize(
            address(token),
            address(0x4200000000000000000000000000000000000006),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );

        deal(address(this), 100_000_000 ether);
        WETH(payable(0x4200000000000000000000000000000000000006)).deposit{ value: 100_000_000 ether }();
        WETH(payable(0x4200000000000000000000000000000000000006)).approve(
            0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4, type(uint256).max
        );

        // (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        uint160 priceLimit = TickMath.getSqrtPriceAtTick(isToken0 ? targetTick + 60 : targetTick - 60);

        ISwapRouter(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: 0x4200000000000000000000000000000000000006,
                tokenOut: address(token),
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
        );

        // (, currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        // for debugging
        // (
        //     uint160 sqrtPriceX96,
        //     int24 tickEnd,
        //     uint16 observationIndex,
        //     uint16 observationCardinality,
        //     uint16 observationCardinalityNext,
        //     uint8 feeProtocol,
        //     bool unlocked
        // ) = IUniswapV3Pool(pool).slot0();
        initializer.exitLiquidity(pool);

        (uint128 liquidity,,,,) =
            IUniswapV3Pool(pool).positions(keccak256(abi.encodePacked(address(initializer), tickLower, tickUpper)));
        assertEq(liquidity, 0, "Position liquidity is not empty");
        assertApproxEqAbs(ERC20(token0).balanceOf(address(pool)), 0, 1000, "Pool token0 balance is not empty");
        assertApproxEqAbs(ERC20(token1).balanceOf(address(pool)), 0, 1000, "Pool token1 balance is not empty");
        assertEq(IUniswapV3Pool(pool).liquidity(), 0, "Pool liquidity is not empty");
        assertEq(ERC20(token0).balanceOf(address(initializer)), 0, "Initializer balance0 is not zero");
        assertEq(ERC20(token1).balanceOf(address(initializer)), 0, "Initializer balance1 is not zero");
    }

    function test_exitLiquidity_RevertsWhenAlreadyExited() public {
        address pool = test_exitLiquidity();
        vm.expectRevert(PoolAlreadyExited.selector);
        initializer.exitLiquidity(pool);
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(address(0));
    }

    function test_uniswapV3MintCallback_RevertsWhenSenderNotPool() public {
        vm.expectRevert(OnlyPool.selector);
        initializer.uniswapV3MintCallback(0, 0, abi.encode(CallbackData(address(0), address(0), 0)));
    }

    function test_Initialize_token0AndToken1SamePrice() public {
        // FUCK this test!
        // will be !isToken0
        DERC20 isToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(isToken0) > address(0x4200000000000000000000000000000000000006)) {
            isToken0 =
                new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }
        // will be isToken0
        DERC20 notIsToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(notIsToken0) < address(0x4200000000000000000000000000000000000006)) {
            notIsToken0 =
                new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }
        isToken0.approve(address(initializer), type(uint256).max);
        notIsToken0.approve(address(initializer), type(uint256).max);

        assertTrue(address(isToken0) < address(0x4200000000000000000000000000000000000006), "isToken0 is not token0");
        assertTrue(
            address(notIsToken0) > address(0x4200000000000000000000000000000000000006), "notIsToken0 is not token1"
        );

        IUniswapV3Pool isToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(isToken0),
                address(0x4200000000000000000000000000000000000006),
                1e27,
                bytes32(0),
                abi.encode(
                    InitData({
                        fee: 3000,
                        tickLower: -DEFAULT_UPPER_TICK,
                        tickUpper: -DEFAULT_LOWER_TICK,
                        numPositions: DEFAULT_NUM_POSITIONS,
                        maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                        beneficiaries: new BeneficiaryData[](0)
                    })
                )
            )
        );
        IUniswapV3Pool notIsToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(notIsToken0),
                address(0x4200000000000000000000000000000000000006),
                1e27,
                bytes32(0),
                abi.encode(
                    InitData({
                        fee: 3000,
                        tickLower: DEFAULT_LOWER_TICK,
                        tickUpper: DEFAULT_UPPER_TICK,
                        numPositions: DEFAULT_NUM_POSITIONS,
                        maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                        beneficiaries: new BeneficiaryData[](0)
                    })
                )
            )
        );

        assertEq(isToken0Pool.token0(), address(isToken0), "isToken0Pool token0 is not isToken0");
        assertEq(notIsToken0Pool.token1(), address(notIsToken0), "notIsToken0Pool token1 is not notIsToken0");
        assertEq(
            isToken0Pool.token1(),
            address(0x4200000000000000000000000000000000000006),
            "isToken0Pool token1 is not 0x4200000000000000000000000000000000000006"
        );
        assertEq(
            notIsToken0Pool.token0(),
            address(0x4200000000000000000000000000000000000006),
            "notIsToken0Pool token0 is not 0x4200000000000000000000000000000000000006"
        );

        deal(address(this), 1000 ether);
        WETH(payable(0x4200000000000000000000000000000000000006)).deposit{ value: 1000 ether }();
        WETH(payable(0x4200000000000000000000000000000000000006)).approve(
            0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4, type(uint256).max
        );

        ISwapRouter(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: 0x4200000000000000000000000000000000000006,
                tokenOut: address(isToken0),
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_UPPER_TICK)
            })
        );

        ISwapRouter(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: 0x4200000000000000000000000000000000000006,
                tokenOut: address(notIsToken0),
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_LOWER_TICK)
            })
        );

        uint256 isToken0Balance = isToken0.balanceOf(address(0x666));
        uint256 notIsToken0Balance = notIsToken0.balanceOf(address(0x666));
        assertApproxEqAbs(isToken0Balance, notIsToken0Balance, 1e9, "isToken0 and notIsToken0 balances are not equal");

        (,,, int24 tickUpperIsToken0,,,) = initializer.getState(address(isToken0Pool));
        (,, int24 tickLowerNotIsToken0,,,,) = initializer.getState(address(notIsToken0Pool));

        uint160 sqrtPriceTargetTickIsToken0 = TickMath.getSqrtPriceAtTick(tickUpperIsToken0 + 1);
        uint160 sqrtPriceTargetTickNotIsToken0 = TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0 - 1);

        IQuoterV2 quoter = IQuoterV2(0xC5290058841028F1614F3A6F0F5816cAd0df5E27);

        uint256 poolBalanceIsToken0 = isToken0.balanceOf(address(isToken0Pool));
        uint256 poolBalanceNotIsToken0 = notIsToken0.balanceOf(address(notIsToken0Pool));

        (uint256 maxWethIsToken0,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: 0x4200000000000000000000000000000000000006,
                tokenOut: address(isToken0),
                fee: 3000,
                amount: poolBalanceIsToken0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickUpperIsToken0)
            })
        );

        (uint256 maxWethNotIsToken0,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: 0x4200000000000000000000000000000000000006,
                tokenOut: address(notIsToken0),
                fee: 3000,
                amount: poolBalanceNotIsToken0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0)
            })
        );

        uint256 low = 1000;
        uint256 high = maxWethIsToken0 - 1 ether;
        uint256 amountReceivedIsToken0;
        uint160 sqrtPriceX96AfterIsToken0;
        uint32 initializedTicksCrossedIsToken0;
        uint256 gasEstimateIsToken0;
        while (low < high) {
            uint256 mid = (low + high) / 2;

            (amountReceivedIsToken0, sqrtPriceX96AfterIsToken0, initializedTicksCrossedIsToken0, gasEstimateIsToken0) =
            quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: 0x4200000000000000000000000000000000000006,
                    tokenOut: address(isToken0),
                    fee: 3000,
                    amountIn: mid,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickUpperIsToken0)
                })
            );

            if (sqrtPriceX96AfterIsToken0 < sqrtPriceTargetTickIsToken0) {
                low = mid + 1;
            } else if (sqrtPriceX96AfterIsToken0 > sqrtPriceTargetTickIsToken0) {
                high = mid;
            } else {
                break;
            }
        }

        low = 1000;
        high = maxWethNotIsToken0 - 1 ether;
        uint256 amountReceivedNotIsToken0;
        uint160 sqrtPriceX96AfterNotIsToken0;
        uint32 initializedTicksCrossedNotIsToken0;
        uint256 gasEstimateNotIsToken0;
        while (low < high) {
            uint256 mid = (low + high) / 2;

            (
                amountReceivedNotIsToken0,
                sqrtPriceX96AfterNotIsToken0,
                initializedTicksCrossedNotIsToken0,
                gasEstimateNotIsToken0
            ) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: 0x4200000000000000000000000000000000000006,
                    tokenOut: address(notIsToken0),
                    fee: 3000,
                    amountIn: mid,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0)
                })
            );

            if (sqrtPriceX96AfterNotIsToken0 > sqrtPriceTargetTickNotIsToken0) {
                low = mid + 1;
            } else if (sqrtPriceX96AfterNotIsToken0 < sqrtPriceTargetTickNotIsToken0) {
                high = mid;
            } else {
                break;
            }
        }
        assertApproxEqAbs(
            amountReceivedIsToken0,
            amountReceivedNotIsToken0,
            1e9,
            "amountReceivedIsToken0 and amountReceivedNotIsToken0 are not equal"
        );
    }
    */
}
