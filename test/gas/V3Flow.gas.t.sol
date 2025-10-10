// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import {
    UniswapV3Initializer,
    PoolAlreadyInitialized,
    PoolAlreadyExited,
    OnlyPool,
    CallbackData,
    InitData,
    CannotMigrateInsufficientTick
} from "src/UniswapV3Initializer.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair } from "src/UniswapV2Migrator.sol";
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
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;

function adjustTick(int24 tick, int24 tickSpacing) pure returns (int24) {
    return tick - (tick % tickSpacing);
}

contract V3FlowGas is Test {
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
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET),
            address(0xb055)
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

    function test_v3_flow_gas() public {
        uint256 initialSupply = 1e23;
        uint16 numPositions = 10;
        uint256 maxShareToBeSold = 0.9 ether;
        uint8 numSwaps = 50;
        uint256 zeroForOneSeed = 0.5 ether;
        bytes32 tokenSalt = bytes32(uint256(0xbeef));

        bool isToken0;
        string memory name = "Best Coin";
        string memory symbol = "BEST";
        bytes memory governanceData = abi.encode(name, 7200, 50_400, 0);
        bytes memory tokenFactoryData = abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "");

        // Compute the asset address that will be created
        bytes memory creationCode = type(DERC20).creationCode;
        bytes memory create2Args = abi.encode(
            name,
            symbol,
            initialSupply,
            address(airlock),
            address(airlock),
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );
        address predictedAsset = vm.computeCreate2Address(
            tokenSalt, keccak256(abi.encodePacked(creationCode, create2Args)), address(tokenFactory)
        );
        isToken0 = predictedAsset < address(WETH_MAINNET);

        int24 tickSpacing = IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET).feeAmountTickSpacing(
            uint24(vm.envOr("V3_FEE", uint256(3000)))
        );

        int24 tickLower = adjustTick(isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK, tickSpacing);
        int24 tickUpper = adjustTick(isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK, tickSpacing);
        int24 targetTick = adjustTick(isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_LOWER_TICK, tickSpacing);

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: uint24(vm.envOr("V3_FEE", uint256(3000))),
                tickLower: tickLower,
                tickUpper: tickUpper,
                numPositions: numPositions,
                maxShareToBeSold: maxShareToBeSold
            })
        );

        vm.startSnapshotGas("V3 Flow", "AirlockCreateCall");
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
                tokenSalt
            )
        );
        vm.stopSnapshotGas("V3 Flow", "AirlockCreateCall");

        assertEq(asset, predictedAsset, "Predicted asset address doesn't match actual");

        deal(address(this), 100_000_000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 100_000_000 ether }();
        WETH(payable(WETH_MAINNET)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);
        DERC20(asset).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        // TODO: assert pool balance
        // uint256 balancePool = DERC20(asset).balanceOf(pool);

        // assert the starting price before swaps
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(currentTick, isToken0 ? tickLower : tickUpper);

        // buy some asset to randomly trade against
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        uint256 amountOut = ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: address(asset),
                fee: uint24(vm.envOr("V3_FEE", uint256(3000))),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
        );
        assertEq(amountOut, DERC20(asset).balanceOf(address(this)));

        // perform a bunch of random swaps
        bool zeroForOne;
        uint256 amountIn;
        address tokenIn;
        ISwapRouter.ExactInputSingleParams memory swapParams;
        for (uint8 i; i < numSwaps; i++) {
            zeroForOne = uint256(keccak256(abi.encodePacked(zeroForOneSeed + i))) % 2 == 0;

            tokenIn = ((zeroForOne && isToken0) || (!zeroForOne && !isToken0)) ? asset : WETH_MAINNET;

            amountIn = tokenIn == asset ? DERC20(asset).balanceOf(address(this)) / 10 : 1 ether;

            swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenIn == WETH_MAINNET ? asset : WETH_MAINNET,
                fee: uint24(vm.envOr("V3_FEE", uint256(3000))),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(swapParams);
        }

        uint256 wethBalBeforeMigration = WETH(payable(WETH_MAINNET)).balanceOf(pool);
        uint256 assetBalBeforeMigration = DERC20(asset).balanceOf(pool);

        (, currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        (,, int24 _tickLower, int24 _tickUpper,,,,,) = initializer.getState(pool);
        // console2.log(currentTick);
        // console2.log(_tickLower);
        // console2.log(_tickUpper);
        int24 farTick = isToken0 ? _tickUpper : _tickLower;
        if ((isToken0 && currentTick < farTick) || (!isToken0 && currentTick > farTick)) {
            vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, farTick, currentTick));
            airlock.migrate(asset);
            return;
        } else {
            airlock.migrate(asset);
        }

        uint256 poolBalanceAssetAfter = DERC20(asset).balanceOf(pool);
        uint256 poolBalanceWETHAfter = WETH(payable(WETH_MAINNET)).balanceOf(pool);

        // Allow for some dust
        assertApproxEqAbs(poolBalanceAssetAfter, 0, 1000, "Pool balance of asset is not 0");
        assertApproxEqAbs(poolBalanceWETHAfter, 0, 1000, "Pool balance of WETH is not 0");

        // collect fees
        // TODO: figure out how to use DopplerFixtures._collectAllProtocolFees
        uint256 numeraireProtocolAmount = airlock.getProtocolFees(WETH_MAINNET);
        uint256 assetProtocolAmount = airlock.getProtocolFees(asset);
        vm.startPrank(airlock.owner());
        airlock.collectProtocolFees(address(this), WETH_MAINNET, numeraireProtocolAmount);
        airlock.collectProtocolFees(address(this), asset, assetProtocolAmount);
        vm.stopPrank();

        address integrator = address(this);
        uint256 numeraireIntegratorAmount = airlock.getIntegratorFees(integrator, WETH_MAINNET);
        uint256 assetIntegratorAmount = airlock.getIntegratorFees(integrator, asset);
        vm.startPrank(integrator);
        airlock.collectIntegratorFees(address(this), WETH_MAINNET, numeraireIntegratorAmount);
        airlock.collectIntegratorFees(address(this), asset, assetIntegratorAmount);
        vm.stopPrank();

        // airlock holds no dust
        assertEq(DERC20(asset).balanceOf(address(airlock)), 0);
        assertEq(WETH(payable(WETH_MAINNET)).balanceOf(address(airlock)), 0);

        // liquidity migrated to V2
        (, address timelock,,,,, address migrationPool,,,) = airlock.getAssetData(asset);
        IUniswapV2Pair pair = IUniswapV2Pair(migrationPool);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 wethV2 = uint256(isToken0 ? reserve1 : reserve0);
        uint256 assetV2 = uint256(isToken0 ? reserve0 : reserve1);

        // the balance delta between v2 deposits and pre-migration v3 balances
        uint256 expectedWethV2 = wethBalBeforeMigration - numeraireProtocolAmount - numeraireIntegratorAmount;
        uint256 expectedAssetV2 = assetBalBeforeMigration - assetProtocolAmount - assetIntegratorAmount;
        uint256 wethDelta = expectedWethV2 - wethV2;

        // if the descrepancy between v3 and v2 is large, confirm its in the timelock
        uint256 wethDeltaPercent = wethDelta * 1e18 / expectedWethV2;
        if (wethDeltaPercent > 0.01e18) {
            assertApproxEqAbs(
                WETH(payable(WETH_MAINNET)).balanceOf(timelock),
                wethDelta,
                0.01e18,
                "unaccounted for WETH is NOT in the timelock"
            );
        } else {
            assertApproxEqRel(wethV2, expectedWethV2, 0.01e18, "unaccounted for WETH");
        }

        assertApproxEqRel(assetV2, expectedAssetV2, 0.01e18, "unaccounted for asset");
    }
}
