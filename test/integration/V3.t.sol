// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console } from "forge-std/Test.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import {
    UniswapV3Initializer,
    OnlyAirlock,
    PoolAlreadyInitialized,
    PoolAlreadyExited,
    OnlyPool,
    CallbackData,
    InitData
} from "src/UniswapV3Initializer.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { DERC20 } from "src/DERC20.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import {
    WETH_MAINNET,
    UNISWAP_V3_FACTORY_MAINNET,
    UNISWAP_V3_ROUTER_MAINNET,
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET
} from "test/shared/Addresses.sol";

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = DEFAULT_UPPER_TICK - 16_260;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.15 ether;
uint256 constant DEFAULT_MAX_SHARE_TO_BOND = 0.5 ether;

contract V3Test is Test {
    UniswapV3Initializer public initializer;
    Airlock public airlock;
    UniswapV2Migrator public uniswapV2LiquidityMigrator;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        airlock = new Airlock(address(this));
        initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET)
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);
    }

    function test_exitLiquidity_WorksWhenInvokedByAirlock() public {
        bool isToken0;
        uint256 initialSupply = 100_000_000 ether;
        string memory name = "Best Coin";
        string memory symbol = "BEST";
        bytes memory governanceData = abi.encode(name);
        bytes memory tokenFactoryData = abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0));

        // Compute the asset address that will be created
        bytes32 salt = bytes32(0);
        bytes memory creationCode = type(DERC20).creationCode;
        bytes memory create2Args = abi.encode(
            name, symbol, initialSupply, address(airlock), address(airlock), 0, 0, new address[](0), new uint256[](0)
        );
        address predictedAsset = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(creationCode, create2Args)), address(tokenFactory)
        );

        isToken0 = predictedAsset < address(WETH_MAINNET);

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;
        int24 targetTick = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_LOWER_TICK;

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: 3000,
                tickLower: tickLower,
                tickUpper: tickUpper,
                numPositions: 10,
                maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                maxShareToBond: DEFAULT_MAX_SHARE_TO_BOND
            })
        );

        (address asset, address pool,,,) = airlock.create(
            CreateParams(
                initialSupply,
                initialSupply,
                WETH_MAINNET,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceData,
                initializer,
                poolInitializerData,
                uniswapV2LiquidityMigrator,
                "",
                address(this),
                salt
            )
        );

        assertEq(asset, predictedAsset, "Predicted asset address doesn't match actual");

        deal(address(this), 100_000_000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 100_000_000 ether }();
        WETH(payable(WETH_MAINNET)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        uint256 balancePool = DERC20(asset).balanceOf(pool);

        console.log("balancePool", balancePool);

        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        uint160 priceLimit = TickMath.getSqrtPriceAtTick(isToken0 ? targetTick : targetTick);

        uint256 amountOut = ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: address(asset),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
        );

        priceLimit = TickMath.getSqrtPriceAtTick(isToken0 ? targetTick + 80 : targetTick - 80);
        amountOut = ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: address(asset),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
        );

        assertGt(amountOut, 0, "Amount out is 0");

        (, currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        if (isToken0) {
            assertGt(currentTick, targetTick, "Current tick is not less than target tick");
        } else {
            assertLt(currentTick, targetTick, "Current tick is not greater than target tick");
        }

        airlock.migrate(asset);

        uint256 poolBalanceAssetAfter = DERC20(asset).balanceOf(pool);
        uint256 poolBalanceWETHAfter = DERC20(WETH_MAINNET).balanceOf(pool);

        // Allow for some dust
        assertApproxEqAbs(poolBalanceAssetAfter, 0, 1000, "Pool balance of asset is not 0");
        assertApproxEqAbs(poolBalanceWETHAfter, 0, 1000, "Pool balance of WETH is not 0");
    }
}
