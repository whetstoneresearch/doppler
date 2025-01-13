/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { V4Quoter } from "v4-periphery/src/lens/V4Quoter.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";

import { Airlock, ModuleState, WrongModuleState, SetModuleState } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { InitData, UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IDopplerDeployer } from "src/interfaces/IDopplerDeployer.sol";
import { TickMath } from "lib/v4-core/src/libraries/TickMath.sol";

import { CustomRouter } from "test/shared/CustomRouter.sol";
import { mineV4 } from "test/shared/AirlockMiner.sol";
import { UNISWAP_V2_ROUTER_MAINNET, UNISWAP_V2_FACTORY_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";

// TODO: Reuse these constants from the BaseTest
string constant DEFAULT_TOKEN_NAME = "Test";
string constant DEFAULT_TOKEN_SYMBOL = "TST";
uint256 constant DEFAULT_INITIAL_SUPPLY = 1e27;
uint256 constant DEFAULT_MIN_PROCEEDS = 1 ether;
uint256 constant DEFAULT_MAX_PROCEEDS = 10 ether;
uint256 constant DEFAULT_STARTING_TIME = 1 days;
uint256 constant DEFAULT_ENDING_TIME = 3 days;
int24 constant DEFAULT_GAMMA = 800;
uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;
address constant DEFAULT_OWNER = address(0xdeadbeef);

int24 constant DEFAULT_START_TICK = 6000;
int24 constant DEFAULT_END_TICK = 60_000;
int24 constant DEFAULT_TARGET_TICK = 12_000;

uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;

uint256 constant DEFAULT_PD_SLUGS = 3;

contract AirlockTest is Test, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    UniswapV4Initializer uniswapV4Initializer;
    DopplerDeployer deployer;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        vm.warp(DEFAULT_STARTING_TIME);

        deployFreshManager();

        airlock = new Airlock(address(this));
        tokenFactory = new TokenFactory(address(airlock));
        deployer = new DopplerDeployer(address(airlock), manager);
        uniswapV4Initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984));
        governanceFactory = new GovernanceFactory(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET)
        );

        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(uniswapV4Initializer);
        modules[3] = address(governanceFactory);
        modules[4] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.GovernanceFactory;
        states[4] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);
    }

    function test_setModuleState_SetsState() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        airlock.setModuleState(modules, states);
        assertEq(uint8(airlock.getModuleState(address(0xbeef))), uint8(ModuleState.TokenFactory));
    }

    function test_setModuleState_EmitsEvent() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        vm.expectEmit();
        emit SetModuleState(address(0xbeef), ModuleState.TokenFactory);
        airlock.setModuleState(modules, states);
    }

    function test_setModuleState_RevertsWhenSenderNotOwner() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xb0b)));
        vm.prank(address(0xb0b));
        airlock.setModuleState(modules, states);
    }

    function test_create_DeploysV4() public returns (address, address) {
        bytes memory tokenFactoryData =
            abi.encode(DEFAULT_TOKEN_NAME, DEFAULT_TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0));

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(DEFAULT_START_TICK);

        bytes memory poolInitializerData = abi.encode(
            sqrtPrice,
            DEFAULT_MIN_PROCEEDS,
            DEFAULT_MAX_PROCEEDS,
            DEFAULT_STARTING_TIME,
            DEFAULT_ENDING_TIME,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            DEFAULT_PD_SLUGS
        );

        (bytes32 salt, address hook, address asset) = mineV4(
            address(airlock),
            address(manager),
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            address(0),
            tokenFactory,
            tokenFactoryData,
            uniswapV4Initializer,
            poolInitializerData
        );

        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            address(0),
            tokenFactory,
            tokenFactoryData,
            governanceFactory,
            abi.encode(DEFAULT_TOKEN_NAME),
            uniswapV4Initializer,
            poolInitializerData,
            uniswapV2LiquidityMigrator,
            new bytes(0),
            address(0xb0b),
            salt
        );

        return (hook, asset);
    }

    // TODO: This test should not be here
    function test_migrate() public {
        vm.skip(true);
        (address hook, address asset) = test_create_DeploysV4();

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hook)
        });

        // Deploy swapRouter
        swapRouter = new PoolSwapTest(manager);
        V4Quoter quoter = new V4Quoter(manager);
        CustomRouter router = new CustomRouter(swapRouter, quoter, poolKey, false, true);
        uint256 amountIn = router.computeBuyExactOut(DEFAULT_MIN_PROCEEDS);

        deal(address(this), amountIn);
        router.buyExactOut{ value: amountIn }(DEFAULT_MIN_PROCEEDS);
        vm.warp(DEFAULT_ENDING_TIME);
        airlock.migrate(asset);
    }

    function test_create_RevertsIfWrongTokenFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.TokenFactory, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            WETH_MAINNET,
            ITokenFactory(address(0xdead)),
            new bytes(0),
            governanceFactory,
            new bytes(0),
            uniswapV3Initializer,
            new bytes(0),
            uniswapV2LiquidityMigrator,
            new bytes(0),
            address(0xb0b),
            bytes32(uint256(0xbeef))
        );
    }

    function test_create_RevertsIfWrongGovernanceFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.GovernanceFactory, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            WETH_MAINNET,
            tokenFactory,
            new bytes(0),
            IGovernanceFactory(address(0xdead)),
            new bytes(0),
            uniswapV3Initializer,
            new bytes(0),
            uniswapV2LiquidityMigrator,
            new bytes(0),
            address(0xb0b),
            bytes32(uint256(0xbeef))
        );
    }

    function test_create_RevertsIfWrongPoolInitializer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.PoolInitializer, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            WETH_MAINNET,
            tokenFactory,
            new bytes(0),
            governanceFactory,
            new bytes(0),
            IPoolInitializer(address(0xdead)),
            new bytes(0),
            uniswapV2LiquidityMigrator,
            new bytes(0),
            address(0xb0b),
            bytes32(uint256(0xbeef))
        );
    }

    function test_create_RevertsIfWrongLiquidityMigrator() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.LiquidityMigrator, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            WETH_MAINNET,
            tokenFactory,
            new bytes(0),
            governanceFactory,
            new bytes(0),
            uniswapV3Initializer,
            new bytes(0),
            ILiquidityMigrator(address(0xdead)),
            new bytes(0),
            address(0xb0b),
            bytes32(uint256(0xbeef))
        );
    }

    function test_create_DeploysOnUniswapV3() public {
        bytes memory tokenFactoryData =
            abi.encode(DEFAULT_TOKEN_NAME, DEFAULT_TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0));
        bytes memory governanceFactoryData = abi.encode(DEFAULT_TOKEN_NAME);
        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: uint24(3000),
                tickLower: DEFAULT_START_TICK,
                tickUpper: DEFAULT_END_TICK,
                numPositions: 1,
                maxShareToBeSold: 0.15 ether,
                maxShareToBond: 0.5 ether
            })
        );

        airlock.create(
            DEFAULT_INITIAL_SUPPLY,
            DEFAULT_INITIAL_SUPPLY,
            WETH_MAINNET,
            tokenFactory,
            tokenFactoryData,
            governanceFactory,
            governanceFactoryData,
            uniswapV3Initializer,
            poolInitializerData,
            uniswapV2LiquidityMigrator,
            new bytes(0),
            address(0xb0b),
            bytes32(uint256(0xbeef))
        );
    }
}
