// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import {
    WETH_UNICHAIN_SEPOLIA,
    UNISWAP_V4_POOL_MANAGER_UNICHAIN_SEPOLIA,
    UNISWAP_V4_ROUTER_UNICHAIN_SEPOLIA,
    UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA,
    UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA
} from "test/shared/Addresses.sol";
import { mineV4, MineV4Params } from "test/shared/AirlockMiner.sol";
import { Doppler } from "src/Doppler.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { MAX_TICK_SPACING } from "src/Doppler.sol";
import { DopplerTickLibrary } from "../util/DopplerTickLibrary.sol";

uint256 constant DEFAULT_NUM_TOKENS_TO_SELL = 100_000e18;
uint256 constant DEFAULT_MINIMUM_PROCEEDS = 100e18;
uint256 constant DEFAULT_MAXIMUM_PROCEEDS = 10_000e18;
uint256 constant DEFAULT_STARTING_TIME = 1 days;
uint256 constant DEFAULT_ENDING_TIME = 2 days;
int24 constant DEFAULT_GAMMA = 800;
uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;

uint24 constant DEFAULT_FEE = 3000;
int24 constant DEFAULT_TICK_SPACING = 8;
uint256 constant DEFAULT_NUM_PD_SLUGS = 3;

int24 constant DEFAULT_START_TICK = 1600;
int24 constant DEFAULT_END_TICK = 171_200;

address constant TOKEN_A = address(0x8888);
address constant TOKEN_B = address(0x9999);

uint160 constant SQRT_RATIO_2_1 = 112_045_541_949_572_279_837_463_876_454;

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

contract UniswapV4InitializerTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    UniswapV4Initializer public initializer;
    DopplerDeployer public deployer;
    Airlock public airlock;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;

    IUniswapV2Factory public uniswapV2Factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA);
    IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA);

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);
        manager = new PoolManager(address(this));
        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        migrator = new UniswapV2Migrator(address(airlock), uniswapV2Factory, uniswapV2Router, address(0xb055));

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

        swapRouter = new PoolSwapTest(manager);
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(airlock), "Wrong airlock");
    }

    function test_v4initialize_success() public returns (address, address) {
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

        address numeraire = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);

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
            config.numPDSlugs,
            config.fee,
            config.tickSpacing
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

        (address asset, address pool,,,) = airlock.create(
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

        assertEq(pool, hook, "Wrong pool");
        assertEq(asset, token, "Wrong asset");
        return (hook, asset);
    }

    function test_v4_fee_collection_native() public {
        (address hook, address asset) = test_v4initialize_success();
        address numeraireAddress = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);
        Doppler doppler = Doppler(payable(hook));

        IERC20(asset).approve(address(swapRouter), type(uint256).max);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(asset),
            fee: 3000, // hard coded in V4Initializer
            tickSpacing: 8, // hard coded in V4Initializer
            hooks: IHooks(hook)
        });

        // warp to starting time
        vm.warp(block.timestamp + DEFAULT_STARTING_TIME);

        // swap to generate fees
        swapRouter.swap{ value: 0.1e18 }(
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -0.1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: -0.01e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        swapRouter.swap{ value: 0.1e18 }(
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -0.1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: -0.01e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        // mock out an early exit to test migration
        _mockEarlyExit(doppler);

        // migrate with native ether is successful
        airlock.migrate(asset);

        // protocol collects fees
        address recipient = makeAddr("protocolFeeRecipient");
        uint256 protocolFeesAsset = airlock.protocolFees(asset);
        airlock.collectProtocolFees(recipient, asset, protocolFeesAsset);
        assertGt(protocolFeesAsset, 0); // protocolFeesAsset > 0
        assertEq(IERC20(asset).balanceOf(recipient), protocolFeesAsset);

        uint256 protocolFeesNumeraire = airlock.protocolFees(numeraireAddress);
        airlock.collectProtocolFees(recipient, numeraireAddress, protocolFeesNumeraire);
        assertGt(protocolFeesNumeraire, 0); // protocolFeesNumeraire > 0
        assertEq(recipient.balance, protocolFeesNumeraire);

        // integrator collects fees
        address integratorRecipient = makeAddr("integratorFeeRecipient");
        uint256 integratorFeesAsset = airlock.integratorFees(address(this), asset);
        airlock.collectIntegratorFees(integratorRecipient, asset, integratorFeesAsset);
        assertGt(integratorFeesAsset, 0); // integratorFeesAsset > 0
        assertEq(IERC20(asset).balanceOf(integratorRecipient), integratorFeesAsset);

        uint256 integratorFeesNumeraire = airlock.integratorFees(address(this), numeraireAddress);
        airlock.collectIntegratorFees(integratorRecipient, numeraireAddress, integratorFeesNumeraire);
        assertGt(integratorFeesNumeraire, 0); // integratorFeesNumeraire > 0
        assertEq(integratorRecipient.balance, integratorFeesNumeraire);
    }

    function _mockEarlyExit(
        Doppler doppler
    ) internal {
        // storage slot of earlyExit variable
        // via `forge inspect Doppler storage`
        bytes32 EARLY_EXIT_SLOT = bytes32(uint256(0));

        vm.record();
        doppler.earlyExit();
        (bytes32[] memory reads,) = vm.accesses(address(doppler));
        assertEq(reads.length, 1, "wrong reads");
        assertEq(reads[0], EARLY_EXIT_SLOT, "wrong slot");

        // need to offset the boolean (0x01) by 1 byte since `insufficientProceeds`
        // and `earlyExit` share slot0
        vm.store(address(doppler), EARLY_EXIT_SLOT, bytes32(uint256(0x0100)));

        assertTrue(doppler.earlyExit(), "early exit should be true");
    }

    /*
    function test_fuzz_v4initialize_fee_tickSpacing(uint24 fee, int24 tickSpacing) public {
        fee = uint24(bound(fee, 0, 1_000_000)); // 0.00% to 100%
        tickSpacing = int24(bound(tickSpacing, 1, MAX_TICK_SPACING));
        int24 gamma = (DEFAULT_GAMMA / tickSpacing) * tickSpacing; // align gamma with tickSpacing, rounding down

        DopplerConfig memory config = DopplerConfig({
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            minimumProceeds: DEFAULT_MINIMUM_PROCEEDS,
            maximumProceeds: DEFAULT_MAXIMUM_PROCEEDS,
            startingTime: block.timestamp + DEFAULT_STARTING_TIME,
            endingTime: block.timestamp + DEFAULT_ENDING_TIME,
            gamma: gamma,
            epochLength: DEFAULT_EPOCH_LENGTH,
            fee: fee,
            tickSpacing: tickSpacing,
            numPDSlugs: DEFAULT_NUM_PD_SLUGS
        });

        address numeraire = Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO);
        bool isToken0 = false; // numeraire native Ether is address(0) so asset is always token1

        bytes memory tokenFactoryData =
            abi.encode("Best Token", "BEST", 1e18, 365 days, new address[](0), new uint256[](0));
        bytes memory governanceFactoryData = abi.encode("Best Token");

        int24 startTick = DopplerTickLibrary.alignComputedTickWithTickSpacing(isToken0, DEFAULT_START_TICK, tickSpacing);
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(startTick);
        int24 endTick = DopplerTickLibrary.alignComputedTickWithTickSpacing(isToken0, DEFAULT_END_TICK, tickSpacing);

        bytes memory poolInitializerData = abi.encode(
            sqrtPrice,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            startTick,
            endTick,
            config.epochLength,
            config.gamma,
            isToken0,
            config.numPDSlugs,
            config.fee,
            config.tickSpacing
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

        (address asset, address pool,,,) = airlock.create(
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

        assertEq(pool, hook, "Wrong pool");
        assertEq(asset, token, "Wrong asset");

        // confirm the pool is initialized
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(asset)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        assertEq(sqrtPriceX96, sqrtPrice, "Wrong starting price");
    }
    */
}
