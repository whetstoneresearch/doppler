/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console } from "forge-std/Test.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

import { TickMath } from "lib/v4-core/src/libraries/TickMath.sol";
import {
    UniswapV3Initializer,
    OnlyAirlock,
    PoolAlreadyInitialized,
    PoolAlreadyExited,
    OnlyPool,
    CallbackData
} from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";

import { WETH_MAINNET, UNISWAP_V3_FACTORY_MAINNET, UNISWAP_V3_ROUTER_MAINNET } from "test/shared/Addresses.sol";

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = 167_520 + 12_000;

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
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK))
        );

        assertEq(token.balanceOf(address(initializer)), 0, "Wrong initializer balance");
        // assertEq(token.balanceOf(pool), 1e27, "Wrong pool balance");
        // assertEq(token.balanceOf(address(this)), 1e27, "Wrong this balance");

        uint128 totalLiquidity = IUniswapV3Pool(pool).liquidity();
        assertTrue(totalLiquidity > 0, "Wrong total liquidity");
        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(initializer), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK)))
        );
        assertEq(liquidity, totalLiquidity, "Wrong liquidity");
    }

    function test_initialize_RevertsIfAlreadyInitialized() public {
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        token.approve(address(initializer), type(uint256).max);

        initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK))
        );

        vm.expectRevert(PoolAlreadyInitialized.selector);
        initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK))
        );
    }

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(OnlyAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }

    function test_exitLiquidity() public returns (address pool) {
        bool isToken0;
        DERC20 token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        while (address(token) < address(WETH_MAINNET)) {
            token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        }

        isToken0 = address(token) < address(WETH_MAINNET);
        token.approve(address(initializer), type(uint256).max);

        pool = initializer.initialize(
            address(token),
            address(WETH_MAINNET),
            1e27,
            bytes32(0),
            abi.encode(uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK), int24(DEFAULT_LOWER_TICK))
        );

        deal(address(this), 1000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 1000 ether }();
        WETH(payable(WETH_MAINNET)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        // (, int24 tickStart,,,,,) = IUniswapV3Pool(pool).slot0();

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: address(token),
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: isToken0
                    ? TickMath.getSqrtPriceAtTick(DEFAULT_UPPER_TICK)
                    : TickMath.getSqrtPriceAtTick(DEFAULT_LOWER_TICK)
            })
        );

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

        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(initializer), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK)))
        );
        assertEq(liquidity, 0, "Position liquidity is not empty");
        assertApproxEqAbs(ERC20(token0).balanceOf(address(pool)), 0, 10, "Pool token0 balance is not empty");
        assertApproxEqAbs(ERC20(token1).balanceOf(address(pool)), 0, 10, "Pool token1 balance is not empty");
        assertEq(IUniswapV3Pool(pool).liquidity(), 0, "Pool liquidity is not empty");
    }

    function test_exitLiquidity_RevertsWhenAlreadyExited() public {
        address pool = test_exitLiquidity();
        vm.expectRevert(PoolAlreadyExited.selector);
        initializer.exitLiquidity(pool);
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(OnlyAirlock.selector);
        initializer.exitLiquidity(address(0));
    }

    function test_uniswapV3MintCallback_RevertsWhenSenderNotPool() public {
        vm.expectRevert(OnlyPool.selector);
        initializer.uniswapV3MintCallback(0, 0, abi.encode(CallbackData(address(0), address(0), 0)));
    }

    function test_Initialize_token0AndToken1SamePrice() public {
        // will be !isToken0
        DERC20 isToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        while (address(isToken0) > address(WETH_MAINNET)) {
            isToken0 = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        }
        // will be isToken0
        DERC20 notIsToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        while (address(notIsToken0) < address(WETH_MAINNET)) {
            notIsToken0 =
                new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0));
        }
        isToken0.approve(address(initializer), type(uint256).max);
        notIsToken0.approve(address(initializer), type(uint256).max);

        assertTrue(address(isToken0) < address(WETH_MAINNET), "isToken0 is not token0");
        assertTrue(address(notIsToken0) > address(WETH_MAINNET), "notIsToken0 is not token1");

        IUniswapV3Pool isToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(isToken0),
                address(WETH_MAINNET),
                1e27,
                bytes32(0),
                abi.encode(
                    uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK), int24(DEFAULT_LOWER_TICK)
                )
            )
        );
        IUniswapV3Pool notIsToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(notIsToken0),
                address(WETH_MAINNET),
                1e27,
                bytes32(0),
                abi.encode(
                    uint24(3000), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK), int24(DEFAULT_LOWER_TICK)
                )
            )
        );

        assertEq(isToken0Pool.token0(), address(isToken0), "isToken0Pool token0 is not isToken0");
        assertEq(notIsToken0Pool.token1(), address(notIsToken0), "notIsToken0Pool token1 is not notIsToken0");
        assertEq(isToken0Pool.token1(), address(WETH_MAINNET), "isToken0Pool token1 is not WETH_MAINNET");
        assertEq(notIsToken0Pool.token0(), address(WETH_MAINNET), "notIsToken0Pool token0 is not WETH_MAINNET");

        deal(address(this), 1000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 1000 ether }();
        WETH(payable(WETH_MAINNET)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: address(isToken0),
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_UPPER_TICK)
            })
        );

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
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

        (,,,, int24 targetTickIsToken0,,,) = UniswapV3Initializer(initializer).getState(address(isToken0Pool));
        (,,,, int24 targetTickNotIsToken0,,,) = UniswapV3Initializer(initializer).getState(address(notIsToken0Pool));
        assertEq(targetTickIsToken0, targetTickNotIsToken0, "targetTicks are not equal");
    }
}
