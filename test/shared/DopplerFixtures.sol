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
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import {
    WETH_UNICHAIN_SEPOLIA,
    UNISWAP_V4_POOL_MANAGER_UNICHAIN_SEPOLIA,
    UNISWAP_V4_ROUTER_UNICHAIN_SEPOLIA,
    UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA,
    UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA
} from "test/shared/Addresses.sol";
import { mineV4, MineV4Params } from "test/shared/AirlockMiner.sol";
import { Doppler } from "src/Doppler.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { MAX_TICK_SPACING } from "src/Doppler.sol";
import { DopplerTickLibrary } from "../util/DopplerTickLibrary.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { MockLiquidityMigrator } from "test/shared/mock/MockLiquidityMigrator.sol";

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
    uint256 epochLength;
    uint256 numPDSlugs;
}

contract DopplerFixtures is Deployers {
    using StateLibrary for IPoolManager;

    // a low address so numeraire is always token0 and asset is always token1
    MockERC20 public numeraire0 = MockERC20(address(0xc0ffee));

    // a high address so numeraire is always token1 and asset is always token0
    MockERC20 public numeraire1 = MockERC20(address(0xFffFFf00C0ffEE00000000000000000000000000));

    UniswapV4Initializer public initializer;
    DopplerDeployer public deployer;
    Airlock public airlock;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;
    MockLiquidityMigrator public mockMigrator;

    IUniswapV2Factory public uniswapV2Factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA);
    IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA);

    /// @dev Deploy and mint 10_000_000 mock tokens
    function _deployMockNumeraire() internal {
        MockERC20 m0 = new MockERC20("Mock Numeraire0", "Mock0", 18);
        vm.etch(address(numeraire0), address(m0).code);
        numeraire0.mint(address(this), 10_000_000e18);

        MockERC20 m1 = new MockERC20("Mock Numeraire1", "Mock1", 18);
        vm.etch(address(numeraire1), address(m1).code);
        numeraire1.mint(address(this), 10_000_000e18);
    }

    /// @dev a Unichain fork should be activated with `vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);`
    function _deployAirlockAndModules() internal {
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
    }

    function _defaultDopplerConfig() internal view returns (DopplerConfig memory) {
        return DopplerConfig({
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            minimumProceeds: DEFAULT_MINIMUM_PROCEEDS,
            maximumProceeds: DEFAULT_MAXIMUM_PROCEEDS,
            startingTime: block.timestamp + DEFAULT_STARTING_TIME,
            endingTime: block.timestamp + DEFAULT_ENDING_TIME,
            epochLength: DEFAULT_EPOCH_LENGTH,
            numPDSlugs: DEFAULT_NUM_PD_SLUGS
        });
    }

    /// @dev Create a default auction with native Ether as the numeraire
    function _airlockCreateNative() internal returns (address, PoolKey memory) {
        // because numeraire is address(0), asset is always token1
        return _airlockCreate(Currency.unwrap(CurrencyLibrary.ADDRESS_ZERO), false);
    }

    /// @dev Create a default auction
    function _airlockCreate(address _numeraire, bool _isAssetToken0) internal returns (address, PoolKey memory) {
        return
            _airlockCreate(_numeraire, _isAssetToken0, address(this), DEFAULT_FEE, DEFAULT_TICK_SPACING, migrator, "");
    }

    function _airlockCreate(
        address _numeraire,
        bool _isAssetToken0,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address, PoolKey memory) {
        return _airlockCreate(_numeraire, _isAssetToken0, address(this), fee, tickSpacing, migrator, "");
    }

    /// @dev Create an auction with custom parameters
    function _airlockCreate(
        address _numeraire,
        bool _isAssetToken0,
        address _integrator,
        uint24 _fee,
        int24 _tickSpacing,
        ILiquidityMigrator _migrator,
        bytes memory _migratorInitializeData
    ) internal returns (address _asset, PoolKey memory _poolKey) {
        DopplerConfig memory config = _defaultDopplerConfig();

        int24 startTick =
            DopplerTickLibrary.alignComputedTickWithTickSpacing(_isAssetToken0, DEFAULT_START_TICK, _tickSpacing);
        int24 endTick =
            DopplerTickLibrary.alignComputedTickWithTickSpacing(_isAssetToken0, DEFAULT_END_TICK, _tickSpacing);
        int24 gamma = (DEFAULT_GAMMA / _tickSpacing) * _tickSpacing; // align gamma with tickSpacing, rounding down

        bytes memory tokenFactoryData = _defaultTokenFactoryData();
        bytes memory governanceFactoryData = _defaultGovernanceFactoryData();

        bytes memory poolInitializerData = abi.encode(
            TickMath.getSqrtPriceAtTick(startTick),
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            startTick,
            endTick,
            config.epochLength,
            gamma,
            _isAssetToken0,
            config.numPDSlugs,
            _fee,
            _tickSpacing
        );

        (bytes32 salt, address hook, address token) = mineV4(
            MineV4Params(
                address(airlock),
                address(manager),
                config.numTokensToSell,
                config.numTokensToSell,
                _numeraire,
                ITokenFactory(address(tokenFactory)),
                tokenFactoryData,
                initializer,
                poolInitializerData
            )
        );

        address hookContract;
        (_asset, hookContract,,,) = airlock.create(
            CreateParams(
                config.numTokensToSell,
                config.numTokensToSell,
                _numeraire,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceFactoryData,
                initializer,
                poolInitializerData,
                _migrator,
                _migratorInitializeData,
                _integrator,
                salt
            )
        );
        _poolKey = PoolKey({
            currency0: Currency.wrap(_numeraire),
            currency1: Currency.wrap(_asset),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(hook)
        });
        assertEq(_asset, token, "Wrong asset");
        assertEq(hook, hookContract, "Wrong hook");
    }

    function _defaultTokenFactoryData() internal pure returns (bytes memory) {
        return abi.encode("Best Token", "BEST", 1e18, 365 days, new address[](0), new uint256[](0), "");
    }

    function _defaultGovernanceFactoryData() internal pure returns (bytes memory) {
        return abi.encode("Best Token");
    }

    function _mockEarlyExit(
        Doppler doppler
    ) internal {
        // storage slot of `earlyExit` variable is slot 0
        // (via `forge inspect Doppler storage`)
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
}
