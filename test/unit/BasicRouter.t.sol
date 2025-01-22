// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import {
    WETH_MAINNET,
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET,
    UNISWAP_V3_FACTORY_MAINNET,
    UNISWAP_V3_ROUTER_MAINNET
} from "test/shared/Addresses.sol";
import { mineV4, MineV4Params } from "test/shared/AirlockMiner.sol";
import { RouterParameters } from "@universal-router/types/RouterParameters.sol";
import { BasicRouter } from "../shared/BasicRouter.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Doppler } from "src/Doppler.sol";
import { PoolKey, Currency } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { UniswapV3Initializer } from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { InitData } from "src/UniswapV3Initializer.sol";

uint256 constant DEFAULT_NUM_TOKENS_TO_SELL = 100_000e18;
uint256 constant DEFAULT_MINIMUM_PROCEEDS = 100e18;
uint256 constant DEFAULT_MAXIMUM_PROCEEDS = 10_000e18;
uint256 constant DEFAULT_STARTING_TIME = 1 days;
uint256 constant DEFAULT_ENDING_TIME = 2 days;
int24 constant DEFAULT_GAMMA = 800;
uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;

// default to feeless case for now
uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;
uint256 constant DEFAULT_NUM_PD_SLUGS = 3;

int24 constant DEFAULT_START_TICK = 1600;
int24 constant DEFAULT_END_TICK = 171_200;

address constant TOKEN_A = address(0x8888);
address constant TOKEN_B = address(0x9999);

uint160 constant SQRT_RATIO_2_1 = 112_045_541_949_572_279_837_463_876_454;

bytes32 constant V3_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
bytes32 constant V2_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

struct DopplerConfig {
    uint256 numTokensToSell;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 startingTime;
    uint256 endingTime;
    int24 gamma;
    uint256 epochLength;
    uint24 fee;
    int24 tickSpacing;
    uint256 numPDSlugs;
}

contract BasicRouterTestV4 is Test, Deployers {
    UniswapV4Initializer public initializer;
    DopplerDeployer public deployer;
    Airlock public airlock;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;

    IUniswapV2Factory public uniswapV2Factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET);
    IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET);
    IUniswapV3Factory public uniswapV3Factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET);

    Doppler pool;
    address numeraire = address(0);
    address asset;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        manager = new PoolManager(address(this));
        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        migrator = new UniswapV2Migrator(address(airlock), uniswapV2Factory, uniswapV2Router);

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);

        DopplerConfig memory config = DopplerConfig({
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            minimumProceeds: DEFAULT_MINIMUM_PROCEEDS,
            maximumProceeds: DEFAULT_MAXIMUM_PROCEEDS,
            startingTime: block.timestamp + DEFAULT_STARTING_TIME,
            endingTime: block.timestamp + DEFAULT_ENDING_TIME,
            gamma: DEFAULT_GAMMA,
            epochLength: DEFAULT_EPOCH_LENGTH,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            numPDSlugs: DEFAULT_NUM_PD_SLUGS
        });

        bytes memory tokenFactoryData =
            abi.encode("Best Token", "BEST", 1e18, 365 days, new address[](0), new uint256[](0), "");
        bytes memory governanceFactoryData = abi.encode("Best Token");

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(DEFAULT_START_TICK);

        bytes memory poolInitializerData = abi.encode(
            sqrtPrice,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            config.epochLength,
            config.gamma,
            false, // isToken0 will always be false using native token
            config.numPDSlugs
        );

        (bytes32 salt, address hook, address token) = mineV4(
            MineV4Params(
                address(airlock),
                address(manager),
                config.numTokensToSell,
                config.numTokensToSell,
                numeraire,
                ITokenFactory(address(tokenFactory)),
                tokenFactoryData,
                initializer,
                poolInitializerData
            )
        );

        deal(address(this), 100_000_000 ether);

        (address assetAddress, address poolAddress,,,) = airlock.create(
            CreateParams(
                config.numTokensToSell,
                config.numTokensToSell,
                numeraire,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceFactoryData,
                initializer,
                poolInitializerData,
                migrator,
                "",
                address(this),
                salt
            )
        );

        asset = assetAddress;
        pool = Doppler(payable(poolAddress));

        assertEq(address(pool), hook, "Wrong pool");
        assertEq(asset, token, "Wrong asset");
    }

    function test_exactInputSingleEthInput() public payable {
        address weth = WETH_MAINNET;
        RouterParameters memory params = RouterParameters({
            permit2: address(0),
            weth9: weth,
            v2Factory: address(uniswapV2Factory),
            v3Factory: address(uniswapV3Factory),
            pairInitCodeHash: V2_INIT_CODE_HASH,
            poolInitCodeHash: V3_INIT_CODE_HASH,
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0)
        });

        UniversalRouter universalRouter = new UniversalRouter(params);
        BasicRouter router = new BasicRouter(address(universalRouter));

        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = pool.poolKey();
        PoolKey memory key =
            PoolKey({ currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks });

        BalanceDelta delta =
            router.exactInputSingleV4{ value: 1 ether }(key, true, 1 ether, 1 ether, "", block.timestamp + 1000);

        assertEq(delta.amount0(), -1 ether, "Wrong delta");
        assertGt(delta.amount1(), 0, "Wrong delta");
    }

    function test_exactOutputSingleEthInput() public payable {
        address weth = WETH_MAINNET;
        RouterParameters memory params = RouterParameters({
            permit2: address(0),
            weth9: weth,
            v2Factory: address(uniswapV2Factory),
            v3Factory: address(uniswapV3Factory),
            pairInitCodeHash: V2_INIT_CODE_HASH,
            poolInitCodeHash: V3_INIT_CODE_HASH,
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0)
        });

        UniversalRouter universalRouter = new UniversalRouter(params);
        BasicRouter router = new BasicRouter(address(universalRouter));

        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = pool.poolKey();
        PoolKey memory key =
            PoolKey({ currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks });

        BalanceDelta delta =
            router.exactOutputSingleV4{ value: 1 ether }(key, true, 1 ether, 1 ether, "", block.timestamp + 1000);

        assertLt(delta.amount0(), 0, "Wrong delta0");
        assertEq(delta.amount1(), 1 ether, "Wrong delta1");
    }
}

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = DEFAULT_UPPER_TICK - 16_260;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.15 ether;
uint256 constant DEFAULT_MAX_SHARE_TO_BOND = 0.5 ether;

contract BasicRouterTestV3 is Test, Deployers {
    UniswapV3Initializer public initializer;
    Airlock public airlock;
    UniswapV2Migrator public uniswapV2LiquidityMigrator;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    IUniswapV2Factory public uniswapV2Factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET);
    IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET);
    IUniswapV3Factory public uniswapV3Factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET);

    BasicRouter public router;
    UniversalRouter public universalRouter;

    bool isToken0;
    address pool;
    address asset;

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

        uint256 initialSupply = 100_000_000 ether;
        string memory name = "Best Coin";
        string memory symbol = "BEST";
        bytes memory governanceData = abi.encode(name);
        bytes memory tokenFactoryData = abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "");

        // Compute the asset address that will be created
        bytes32 salt = bytes32(0);
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
            salt, keccak256(abi.encodePacked(creationCode, create2Args)), address(tokenFactory)
        );

        isToken0 = predictedAsset < address(WETH_MAINNET);

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;

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

        (address assetAddress, address poolAddress,,,) = airlock.create(
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

        assertEq(assetAddress, predictedAsset, "Predicted asset address doesn't match actual");

        pool = poolAddress;
        asset = assetAddress;

        deal(address(this), 100_000_000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 100_000_000 ether }();

        RouterParameters memory params = RouterParameters({
            permit2: address(0),
            weth9: WETH_MAINNET,
            v2Factory: address(uniswapV2Factory),
            v3Factory: address(uniswapV3Factory),
            pairInitCodeHash: V2_INIT_CODE_HASH,
            poolInitCodeHash: V3_INIT_CODE_HASH,
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0)
        });

        universalRouter = new UniversalRouter(params);
        router = new BasicRouter(address(universalRouter));
        WETH(payable(WETH_MAINNET)).approve(address(router), type(uint256).max);
    }

    function test_exactInputSingleWethInputV3() public payable {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();

        uint256 balance0Before = DERC20(token0).balanceOf(address(this));
        uint256 balance1Before = DERC20(token1).balanceOf(address(this));

        BalanceDelta delta = router.exactInputSingleV3(
            address(pool), address(this), !isToken0, 1 ether, 1 ether, block.timestamp + 1000
        );

        uint256 balance0After = DERC20(token0).balanceOf(address(this));
        uint256 balance1After = DERC20(token1).balanceOf(address(this));

        assertEq(delta.amount0(), 0, "Wrong delta0");
        assertEq(delta.amount1(), 0, "Wrong delta1");

        assertGt(isToken0 ? balance0After : balance1After, 0, "Wrong amount");
        assertEq(isToken0 ? balance1Before - balance1After : balance0Before - balance0After, 1 ether, "Wrong amount");
    }

    function test_exactOutputSingleWethInputV3() public payable {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();

        uint256 balance0Before = DERC20(token0).balanceOf(address(this));
        uint256 balance1Before = DERC20(token1).balanceOf(address(this));

        BalanceDelta delta = router.exactOutputSingleV3(
            address(pool), address(this), !isToken0, 1 ether, 1_000_000 ether, block.timestamp + 1000
        );

        uint256 balance0After = DERC20(token0).balanceOf(address(this));
        uint256 balance1After = DERC20(token1).balanceOf(address(this));

        assertEq(delta.amount0(), 0, "Wrong delta0");
        assertEq(delta.amount1(), 0, "Wrong delta1");

        assertEq(isToken0 ? balance0After : balance1After, 1 ether, "Wrong amount");
        assertLt(isToken0 ? balance1After : balance0After, isToken0 ? balance1Before : balance0Before, "Wrong amount");
    }
}
