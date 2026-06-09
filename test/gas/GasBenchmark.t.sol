// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// forge-config: default.isolate = true

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { LaunchpadGovernanceFactory } from "src/governance/LaunchpadGovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import {
    InitData as LockableV3InitData,
    LockableUniswapV3Initializer
} from "src/initializers/LockableUniswapV3Initializer.sol";
import { UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import { IUniswapV2Factory, UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";
import { DopplerERC20V1, VestingSchedule } from "src/tokens/DopplerERC20V1.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { deployUniswapV4Initializer } from "test/integration/UniswapV4Initializer.t.sol";
import {
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET,
    UNISWAP_V3_FACTORY_MAINNET,
    UNISWAP_V3_ROUTER_MAINNET,
    WETH_MAINNET
} from "test/shared/Addresses.sol";
import {
    DEFAULT_EPOCH_LENGTH,
    DEFAULT_GAMMA,
    DEFAULT_MAXIMUM_PROCEEDS,
    DEFAULT_MINIMUM_PROCEEDS
} from "test/shared/DopplerFixtures.sol";

enum LaunchKind {
    Static,
    Dynamic,
    Multicurve
}

enum MigratorKind {
    NoOp,
    UniswapV2MigratorSplit,
    DopplerHookMigrator
}

enum GovernanceKind {
    NoOpGovernanceFactory,
    LaunchpadGovernanceFactory,
    GovernanceFactory
}

enum BalanceLimitKind {
    Disabled,
    Exempt,
    Applied
}

enum ProceedsSplitKind {
    Disabled,
    Enabled
}

struct PoolInitializerConfig {
    bytes32 salt;
    address predictedAsset;
    address predictedInitialPool;
    bytes data;
}

struct V4SwapParams {
    PoolKey poolKey;
    IPoolManager.SwapParams swapParams;
    PoolSwapTest.TestSettings testSettings;
    uint256 value;
}

contract GasBenchmark is Deployers {
    string internal constant GAS_BENCHMARK_SNAPSHOT = type(GasBenchmark).name;
    uint256 internal constant INITIAL_SUPPLY = 1e23;
    uint256 internal constant NUM_TOKENS_TO_SELL = 1e23;
    uint256 internal constant MAX_BALANCE_LIMIT = 5e22;
    uint256 internal constant BENCHMARK_SWAP_AMOUNT = 0.001 ether;
    uint256 internal constant PROCEEDS_SHARE = 0.1e18;
    address internal constant AIRLOCK_OWNER = address(0xA111);
    address internal constant LAUNCHPAD_MULTISIG = address(0x1A2B);
    address internal constant BENCHMARK_SWAPPER = address(0xBEEFCAFE);
    address internal constant PROCEEDS_RECIPIENT = address(0xFEEDFACE);
    bytes32 internal constant UNISWAP_V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    Airlock public airlock;
    DopplerERC20V1Factory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LaunchpadGovernanceFactory public launchpadGovernanceFactory;
    NoOpGovernanceFactory public noOpGovernanceFactory;
    UniswapV4Initializer public uniswapV4Initializer;
    DopplerHookInitializer public dopplerHookInitializer;
    LockableUniswapV3Initializer public lockableV3Initializer;
    NoOpMigrator public noOpMigrator;
    UniswapV2MigratorSplit public v2Migrator;
    StreamableFeesLockerV2 public locker;
    TopUpDistributor public topUpDistributor;
    DopplerHookMigrator public hookMigrator;
    uint256 internal saltNonce;
    uint256 internal v4SaltCursor;
    LaunchKind internal currentLaunchKind;
    MigratorKind internal currentMigratorKind;
    GovernanceKind internal currentGovernanceKind;
    BalanceLimitKind internal currentBalanceLimitKind;
    ProceedsSplitKind internal currentProceedsSplitKind;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);
        deployFreshManagerAndRouters();

        airlock = new Airlock(AIRLOCK_OWNER);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        launchpadGovernanceFactory = new LaunchpadGovernanceFactory();
        noOpGovernanceFactory = new NoOpGovernanceFactory();

        (, uniswapV4Initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        dopplerHookInitializer = _deployDopplerHookInitializer();
        lockableV3Initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));

        noOpMigrator = new NoOpMigrator(address(airlock));
        topUpDistributor = new TopUpDistributor(address(airlock));
        v2Migrator = new UniswapV2MigratorSplit(
            address(airlock), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), topUpDistributor, WETH_MAINNET
        );

        locker = new StreamableFeesLockerV2(IPoolManager(address(manager)), AIRLOCK_OWNER);
        hookMigrator = DopplerHookMigrator(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo(
            "DopplerHookMigrator",
            abi.encode(address(airlock), address(manager), locker, topUpDistributor),
            address(hookMigrator)
        );

        address[] memory modules = new address[](10);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(launchpadGovernanceFactory);
        modules[3] = address(noOpGovernanceFactory);
        modules[4] = address(uniswapV4Initializer);
        modules[5] = address(dopplerHookInitializer);
        modules[6] = address(lockableV3Initializer);
        modules[7] = address(noOpMigrator);
        modules[8] = address(v2Migrator);
        modules[9] = address(hookMigrator);

        ModuleState[] memory states = new ModuleState[](10);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.GovernanceFactory;
        states[4] = ModuleState.PoolInitializer;
        states[5] = ModuleState.PoolInitializer;
        states[6] = ModuleState.PoolInitializer;
        states[7] = ModuleState.LiquidityMigrator;
        states[8] = ModuleState.LiquidityMigrator;
        states[9] = ModuleState.LiquidityMigrator;

        vm.startPrank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
        locker.approveMigrator(address(hookMigrator));
        topUpDistributor.setPullUp(address(hookMigrator), true);
        topUpDistributor.setPullUp(address(v2Migrator), true);
        vm.stopPrank();
    }

    function test_create_Static_LockableUniswapV3Initializer_NoOpMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.NoOp, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_NoOpMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.NoOp, GovernanceKind.LaunchpadGovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_NoOpMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.NoOp, GovernanceKind.GovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitDisabled_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Disabled,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitExempt_ProceedsSplitDisabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Disabled
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitExempt_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitApplied_ProceedsSplitDisabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Disabled
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitApplied_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Static_LockableUniswapV3Initializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory);
    }

    function test_create_Static_LockableUniswapV3Initializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_NoOpMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.NoOp, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_NoOpMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.NoOp, GovernanceKind.LaunchpadGovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_NoOpMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.NoOp, GovernanceKind.GovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(
            LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(
            LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitDisabled_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Disabled,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitExempt_ProceedsSplitDisabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Disabled
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitExempt_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitApplied_ProceedsSplitDisabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Disabled
        );
    }

    function test_create_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitApplied_ProceedsSplitEnabled()
        public
    {
        _benchmarkCreate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Enabled
        );
    }

    function test_create_Multicurve_DopplerHookInitializer_NoOpMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.NoOp, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Multicurve_DopplerHookInitializer_NoOpMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.NoOp, GovernanceKind.LaunchpadGovernanceFactory);
    }

    function test_create_Multicurve_DopplerHookInitializer_NoOpMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.NoOp, GovernanceKind.GovernanceFactory);
    }

    function test_create_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkCreate(
            LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory
        );
    }

    function test_create_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(
            LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_create_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_create_Multicurve_DopplerHookInitializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_create_Multicurve_DopplerHookInitializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkCreate(
            LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_create_Multicurve_DopplerHookInitializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkCreate(LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Static, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitDisabled_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Disabled,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitExempt_ProceedsSplitDisabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Disabled
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitExempt_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitApplied_ProceedsSplitDisabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Disabled
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_UniswapV2MigratorSplit_GovernanceFactory_BalanceLimitApplied_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Static,
            MigratorKind.UniswapV2MigratorSplit,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_migrate_Static_LockableUniswapV3Initializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Static_LockableUniswapV3Initializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Static, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_migrate_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Dynamic, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Dynamic, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitDisabled_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Disabled,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitExempt_ProceedsSplitDisabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Disabled
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitExempt_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Exempt,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitApplied_ProceedsSplitDisabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Disabled
        );
    }

    function test_migrate_Dynamic_UniswapV4Initializer_DopplerHookMigrator_GovernanceFactory_BalanceLimitApplied_ProceedsSplitEnabled()
        public
    {
        _benchmarkMigrate(
            LaunchKind.Dynamic,
            MigratorKind.DopplerHookMigrator,
            GovernanceKind.GovernanceFactory,
            BalanceLimitKind.Applied,
            ProceedsSplitKind.Enabled
        );
    }

    function test_migrate_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_NoOpGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.NoOpGovernanceFactory
        );
    }

    function test_migrate_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_LaunchpadGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Multicurve_DopplerHookInitializer_UniswapV2MigratorSplit_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Multicurve, MigratorKind.UniswapV2MigratorSplit, GovernanceKind.GovernanceFactory);
    }

    function test_migrate_Multicurve_DopplerHookInitializer_DopplerHookMigrator_NoOpGovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.NoOpGovernanceFactory);
    }

    function test_migrate_Multicurve_DopplerHookInitializer_DopplerHookMigrator_LaunchpadGovernanceFactory() public {
        _benchmarkMigrate(
            LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.LaunchpadGovernanceFactory
        );
    }

    function test_migrate_Multicurve_DopplerHookInitializer_DopplerHookMigrator_GovernanceFactory() public {
        _benchmarkMigrate(LaunchKind.Multicurve, MigratorKind.DopplerHookMigrator, GovernanceKind.GovernanceFactory);
    }

    function _benchmarkCreate(
        LaunchKind launchKind,
        MigratorKind migratorKind,
        GovernanceKind governanceKind
    ) internal {
        vm.pauseGasMetering();
        currentLaunchKind = launchKind;
        currentMigratorKind = migratorKind;
        currentGovernanceKind = governanceKind;
        currentBalanceLimitKind = BalanceLimitKind.Disabled;
        _benchmarkCreate(ProceedsSplitKind.Disabled);
        vm.resumeGasMetering();
    }

    function _benchmarkCreate(
        LaunchKind launchKind,
        MigratorKind migratorKind,
        GovernanceKind governanceKind,
        BalanceLimitKind balanceLimitKind,
        ProceedsSplitKind proceedsSplitKind
    ) internal {
        vm.pauseGasMetering();
        currentLaunchKind = launchKind;
        currentMigratorKind = migratorKind;
        currentGovernanceKind = governanceKind;
        currentBalanceLimitKind = balanceLimitKind;
        _benchmarkCreate(proceedsSplitKind);
        vm.resumeGasMetering();
    }

    function _benchmarkCreate(BalanceLimitKind balanceLimitKind) internal {
        currentBalanceLimitKind = balanceLimitKind;
        _benchmarkCreate(ProceedsSplitKind.Disabled);

        if (_supportsProceedsSplit(currentMigratorKind)) {
            _benchmarkCreate(ProceedsSplitKind.Enabled);
        }
    }

    function _benchmarkCreate(ProceedsSplitKind proceedsSplitKind) internal {
        currentProceedsSplitKind = proceedsSplitKind;
        CreateParams memory params = _createParams();
        string memory name = _snapshotName();

        _startBenchmarkSnapshot(name, "Airlock.create");
        (address asset, address pool,,,) = airlock.create(params);
        _stopBenchmarkSnapshot(name, "Airlock.create");

        _benchmarkInitializerSwaps(currentLaunchKind, asset, pool, name);
    }

    function _benchmarkMigrate(
        LaunchKind launchKind,
        MigratorKind migratorKind,
        GovernanceKind governanceKind
    ) internal {
        vm.pauseGasMetering();
        currentLaunchKind = launchKind;
        currentMigratorKind = migratorKind;
        currentGovernanceKind = governanceKind;
        currentBalanceLimitKind = BalanceLimitKind.Disabled;
        _benchmarkMigrate(ProceedsSplitKind.Disabled);
        vm.resumeGasMetering();
    }

    function _benchmarkMigrate(
        LaunchKind launchKind,
        MigratorKind migratorKind,
        GovernanceKind governanceKind,
        BalanceLimitKind balanceLimitKind,
        ProceedsSplitKind proceedsSplitKind
    ) internal {
        vm.pauseGasMetering();
        currentLaunchKind = launchKind;
        currentMigratorKind = migratorKind;
        currentGovernanceKind = governanceKind;
        currentBalanceLimitKind = balanceLimitKind;
        _benchmarkMigrate(proceedsSplitKind);
        vm.resumeGasMetering();
    }

    function _benchmarkMigrate(BalanceLimitKind balanceLimitKind) internal {
        currentBalanceLimitKind = balanceLimitKind;
        _benchmarkMigrate(ProceedsSplitKind.Disabled);

        if (_supportsProceedsSplit(currentMigratorKind)) {
            _benchmarkMigrate(ProceedsSplitKind.Enabled);
        }
    }

    function _benchmarkMigrate(ProceedsSplitKind proceedsSplitKind) internal {
        currentProceedsSplitKind = proceedsSplitKind;
        CreateParams memory params = _createParams();
        string memory name = _snapshotName();

        (address asset, address pool,,, address migrationPool) = airlock.create(params);
        _prepareMigration(currentLaunchKind, asset, pool);

        _startBenchmarkSnapshot(name, "Airlock.migrate");
        airlock.migrate(asset);
        _stopBenchmarkSnapshot(name, "Airlock.migrate");

        _benchmarkMigratorSwaps(currentLaunchKind, currentMigratorKind, asset, migrationPool, name);
    }

    function _supportsProceedsSplit(MigratorKind migratorKind) internal pure returns (bool) {
        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) return true;
        return migratorKind == MigratorKind.DopplerHookMigrator;
    }

    function _benchmarkInitializerSwaps(
        LaunchKind launchKind,
        address asset,
        address pool,
        string memory name
    ) internal {
        address swapper = BENCHMARK_SWAPPER;
        uint256 assetBalanceBefore = ERC20(asset).balanceOf(swapper);
        _prepareInitializerBuy(launchKind, swapper);

        if (launchKind == LaunchKind.Static) {
            ISwapRouter.ExactInputSingleParams memory swapParams =
                _v3SwapParams(WETH_MAINNET, asset, BENCHMARK_SWAP_AMOUNT, swapper);
            _startBenchmarkSnapshot(name, "initializerBuy");
            _swapV3(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "initializerBuy");
        } else {
            V4SwapParams memory swapParams =
                _v4SwapParams(_initializerPoolKey(launchKind, asset, pool), asset, BENCHMARK_SWAP_AMOUNT, true);
            _startBenchmarkSnapshot(name, "initializerBuy");
            _swapV4(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "initializerBuy");
        }

        uint256 assetAmount = ERC20(asset).balanceOf(swapper) - assetBalanceBefore;
        assertGt(assetAmount, 0, "initializer buy produced no asset");

        assetAmount /= 2;
        if (assetAmount == 0) assetAmount = ERC20(asset).balanceOf(swapper);
        _approveInitializerSell(launchKind, asset, assetAmount, swapper);

        if (launchKind == LaunchKind.Static) {
            ISwapRouter.ExactInputSingleParams memory swapParams =
                _v3SwapParams(asset, WETH_MAINNET, assetAmount, swapper);
            _startBenchmarkSnapshot(name, "initializerSell");
            _swapV3(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "initializerSell");
        } else {
            V4SwapParams memory swapParams =
                _v4SwapParams(_initializerPoolKey(launchKind, asset, pool), asset, assetAmount, false);
            _startBenchmarkSnapshot(name, "initializerSell");
            _swapV4(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "initializerSell");
        }
    }

    function _benchmarkMigratorSwaps(
        LaunchKind launchKind,
        MigratorKind migratorKind,
        address asset,
        address migrationPool,
        string memory name
    ) internal {
        if (migratorKind == MigratorKind.NoOp) return;

        address swapper = BENCHMARK_SWAPPER;
        uint256 assetBalanceBefore = ERC20(asset).balanceOf(swapper);
        _prepareMigratorBuy(launchKind, migratorKind, swapper);

        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) {
            address[] memory path = _v2Path(WETH_MAINNET, asset);
            _startBenchmarkSnapshot(name, "migratorBuy");
            _swapV2(path, BENCHMARK_SWAP_AMOUNT, swapper);
            _stopBenchmarkSnapshot(name, "migratorBuy");
        } else {
            V4SwapParams memory swapParams = _v4SwapParams(
                _migratorPoolKey(launchKind, migratorKind, asset, migrationPool), asset, BENCHMARK_SWAP_AMOUNT, true
            );
            _startBenchmarkSnapshot(name, "migratorBuy");
            _swapV4(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "migratorBuy");
        }

        uint256 assetAmount = ERC20(asset).balanceOf(swapper) - assetBalanceBefore;
        assertGt(assetAmount, 0, "migrator buy produced no asset");

        assetAmount /= 2;
        if (assetAmount == 0) assetAmount = ERC20(asset).balanceOf(swapper);
        _approveMigratorSell(migratorKind, asset, assetAmount, swapper);

        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) {
            address[] memory path = _v2Path(asset, WETH_MAINNET);
            _startBenchmarkSnapshot(name, "migratorSell");
            _swapV2(path, assetAmount, swapper);
            _stopBenchmarkSnapshot(name, "migratorSell");
        } else {
            V4SwapParams memory swapParams = _v4SwapParams(
                _migratorPoolKey(launchKind, migratorKind, asset, migrationPool), asset, assetAmount, false
            );
            _startBenchmarkSnapshot(name, "migratorSell");
            _swapV4(swapParams, swapper);
            _stopBenchmarkSnapshot(name, "migratorSell");
        }
    }

    function _startBenchmarkSnapshot(string memory name, string memory metric) internal {
        vm.resumeGasMetering();
        vm.startSnapshotGas(GAS_BENCHMARK_SNAPSHOT, _benchmarkMetric(name, metric));
    }

    function _stopBenchmarkSnapshot(string memory name, string memory metric) internal {
        vm.stopSnapshotGas(GAS_BENCHMARK_SNAPSHOT, _benchmarkMetric(name, metric));
        vm.pauseGasMetering();
    }

    function _benchmarkMetric(string memory name, string memory metric) internal pure returns (string memory) {
        return string.concat(name, "/", metric);
    }

    function _createParams() internal returns (CreateParams memory params) {
        PoolInitializerConfig memory poolConfig = _poolInitializerConfig();
        params.initialSupply = INITIAL_SUPPLY;
        params.numTokensToSell = NUM_TOKENS_TO_SELL;
        params.numeraire = currentLaunchKind == LaunchKind.Static ? WETH_MAINNET : address(0);
        params.tokenFactory = tokenFactory;
        params.tokenFactoryData = _tokenFactoryData(poolConfig.predictedInitialPool);

        (params.governanceFactory, params.governanceFactoryData) = _governanceFactory(currentGovernanceKind);
        params.poolInitializer = _poolInitializer(currentLaunchKind);
        params.poolInitializerData = poolConfig.data;
        params.liquidityMigrator = _liquidityMigrator(currentMigratorKind);
        params.liquidityMigratorData = _liquidityMigratorData(currentMigratorKind, currentProceedsSplitKind);
        params.integrator = address(0);
        params.salt = poolConfig.salt;
    }

    function _poolInitializerConfig() internal returns (PoolInitializerConfig memory poolConfig) {
        poolConfig.salt = _nextSalt();
        poolConfig.predictedAsset = _predictAsset(poolConfig.salt);

        if (currentLaunchKind == LaunchKind.Dynamic) {
            poolConfig.data = _uniswapV4InitializerData();
            (poolConfig.salt, poolConfig.predictedInitialPool, poolConfig.predictedAsset) =
                _mineV4DopplerERC20V1(poolConfig.data);
        } else if (currentLaunchKind == LaunchKind.Static) {
            poolConfig.predictedInitialPool = _computeV3Pool(poolConfig.predictedAsset, WETH_MAINNET, 3000);
            poolConfig.data = _lockableV3InitializerData(poolConfig.predictedAsset);
        } else {
            poolConfig.predictedInitialPool = address(dopplerHookInitializer);
            poolConfig.data = _dopplerHookInitializerData();
        }
    }

    function _nextSalt() internal returns (bytes32) {
        return bytes32(++saltNonce);
    }

    function _tokenFactoryData(address predictedInitialPool) internal view returns (bytes memory) {
        return _tokenFactoryData(
            currentBalanceLimitKind,
            _excludedFromBalanceLimit(predictedInitialPool, _predictTimelock(currentGovernanceKind))
        );
    }

    function _excludedFromBalanceLimit(
        address predictedInitialPool,
        address predictedTimelock
    ) internal view returns (address[] memory excluded) {
        if (currentBalanceLimitKind == BalanceLimitKind.Disabled) return new address[](0);

        excluded = new address[](_excludedFromBalanceLimitLength());
        _populateExcludedFromBalanceLimit(excluded, predictedInitialPool, predictedTimelock);
    }

    function _excludedFromBalanceLimitLength() internal view returns (uint256 length) {
        length = 2;
        if (currentLaunchKind != LaunchKind.Static) length++;
        if (currentMigratorKind == MigratorKind.UniswapV2MigratorSplit) length++;
        if (currentMigratorKind == MigratorKind.DopplerHookMigrator) length += 2;
        if (currentBalanceLimitKind == BalanceLimitKind.Exempt) length++;
    }

    function _populateExcludedFromBalanceLimit(
        address[] memory excluded,
        address predictedInitialPool,
        address predictedTimelock
    ) internal view {
        uint256 index;
        excluded[index++] = predictedInitialPool;
        excluded[index++] = predictedTimelock;
        if (currentLaunchKind != LaunchKind.Static) excluded[index++] = address(manager);
        if (currentMigratorKind == MigratorKind.UniswapV2MigratorSplit) excluded[index++] = address(v2Migrator);
        if (currentMigratorKind == MigratorKind.DopplerHookMigrator) {
            excluded[index++] = address(hookMigrator);
            excluded[index++] = address(locker);
        }
        if (currentBalanceLimitKind == BalanceLimitKind.Exempt) excluded[index++] = BENCHMARK_SWAPPER;
    }

    function _prepareMigration(LaunchKind launchKind, address asset, address pool) internal {
        if (launchKind == LaunchKind.Dynamic) {
            _buyUntilDynamicV4CanMigrate(pool);
        } else if (launchKind == LaunchKind.Static) {
            _buyUntilLockableV3CanMigrate(pool, asset);
        } else {
            _swapOnDopplerHookInitializerPool(asset);
        }
    }

    function _prepareInitializerBuy(LaunchKind launchKind, address swapper) internal {
        if (launchKind == LaunchKind.Static) {
            _prepareWethInput(UNISWAP_V3_ROUTER_MAINNET, BENCHMARK_SWAP_AMOUNT, swapper);
        } else {
            deal(swapper, BENCHMARK_SWAP_AMOUNT);
        }
    }

    function _prepareMigratorBuy(LaunchKind launchKind, MigratorKind migratorKind, address swapper) internal {
        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) {
            _prepareWethInput(UNISWAP_V2_ROUTER_MAINNET, BENCHMARK_SWAP_AMOUNT, swapper);
        } else if (launchKind == LaunchKind.Static) {
            _prepareWethInput(address(swapRouter), BENCHMARK_SWAP_AMOUNT, swapper);
        } else {
            deal(swapper, BENCHMARK_SWAP_AMOUNT);
        }
    }

    function _prepareWethInput(address spender, uint256 amount, address swapper) internal {
        deal(swapper, amount);
        vm.startPrank(swapper);
        WETH(payable(WETH_MAINNET)).deposit{ value: amount }();
        ERC20(WETH_MAINNET).approve(spender, amount);
        vm.stopPrank();
    }

    function _approveInitializerSell(LaunchKind launchKind, address asset, uint256 amount, address swapper) internal {
        address spender = launchKind == LaunchKind.Static ? UNISWAP_V3_ROUTER_MAINNET : address(swapRouter);
        vm.prank(swapper);
        ERC20(asset).approve(spender, amount);
    }

    function _approveMigratorSell(MigratorKind migratorKind, address asset, uint256 amount, address swapper) internal {
        address spender =
            migratorKind == MigratorKind.UniswapV2MigratorSplit ? UNISWAP_V2_ROUTER_MAINNET : address(swapRouter);
        vm.prank(swapper);
        ERC20(asset).approve(spender, amount);
    }

    function _v2Path(address tokenIn, address tokenOut) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    function _swapV2(address[] memory path, uint256 amountIn, address swapper) internal {
        vm.prank(swapper);
        IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET)
            .swapExactTokensForTokens(amountIn, 0, path, swapper, block.timestamp);
    }

    function _v3SwapParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address swapper
    ) internal view returns (ISwapRouter.ExactInputSingleParams memory) {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 3000,
            recipient: swapper,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    function _swapV3(ISwapRouter.ExactInputSingleParams memory swapParams, address swapper) internal {
        vm.prank(swapper);
        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET).exactInputSingle(swapParams);
    }

    function _v4SwapParams(
        PoolKey memory poolKey,
        address asset,
        uint256 amountIn,
        bool buyAsset
    ) internal pure returns (V4SwapParams memory swapParams) {
        bool assetIsToken0 = asset == Currency.unwrap(poolKey.currency0);
        bool zeroForOne = buyAsset ? !assetIsToken0 : assetIsToken0;

        swapParams.poolKey = poolKey;
        swapParams.swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapParams.testSettings = PoolSwapTest.TestSettings(false, false);
        swapParams.value = buyAsset
            && Currency.unwrap(assetIsToken0 ? poolKey.currency1 : poolKey.currency0) == address(0)
            ? amountIn
            : 0;
    }

    function _swapV4(V4SwapParams memory swapParams, address swapper) internal {
        vm.prank(swapper);
        swapRouter.swap{ value: swapParams.value }(
            swapParams.poolKey, swapParams.swapParams, swapParams.testSettings, ""
        );
    }

    function _initializerPoolKey(
        LaunchKind launchKind,
        address asset,
        address pool
    ) internal view returns (PoolKey memory poolKey) {
        if (launchKind == LaunchKind.Dynamic) {
            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(pool)).poolKey();
            poolKey = PoolKey({
                currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
            });
        } else {
            PoolStatus status;
            (,,,, status, poolKey,) = dopplerHookInitializer.getState(asset);
            assertEq(uint8(status), uint8(PoolStatus.Initialized));
        }
    }

    function _migratorPoolKey(
        LaunchKind launchKind,
        MigratorKind,
        address asset,
        address
    ) internal view returns (PoolKey memory poolKey) {
        address numeraire = launchKind == LaunchKind.Static ? WETH_MAINNET : address(0);
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        (, poolKey,,,,,,) = hookMigrator.getAssetData(token0, token1);
    }

    function _poolInitializer(LaunchKind launchKind) internal view returns (IPoolInitializer) {
        if (launchKind == LaunchKind.Dynamic) return uniswapV4Initializer;
        if (launchKind == LaunchKind.Static) return lockableV3Initializer;
        return dopplerHookInitializer;
    }

    function _liquidityMigrator(MigratorKind migratorKind) internal view returns (ILiquidityMigrator) {
        if (migratorKind == MigratorKind.NoOp) return noOpMigrator;
        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) return v2Migrator;
        return hookMigrator;
    }

    function _governanceFactory(GovernanceKind governanceKind)
        internal
        view
        returns (IGovernanceFactory selectedGovernanceFactory, bytes memory data)
    {
        if (governanceKind == GovernanceKind.NoOpGovernanceFactory) {
            return (noOpGovernanceFactory, new bytes(0));
        }
        if (governanceKind == GovernanceKind.LaunchpadGovernanceFactory) {
            return (launchpadGovernanceFactory, abi.encode(LAUNCHPAD_MULTISIG));
        }
        return (governanceFactory, abi.encode("Test Token", uint48(7200), uint32(50_400), uint256(0)));
    }

    function _predictTimelock(GovernanceKind governanceKind) internal view returns (address) {
        if (governanceKind == GovernanceKind.NoOpGovernanceFactory) return address(0xdead);
        if (governanceKind == GovernanceKind.LaunchpadGovernanceFactory) return LAUNCHPAD_MULTISIG;

        address timelockFactory = address(governanceFactory.timelockFactory());
        return vm.computeCreateAddress(timelockFactory, vm.getNonce(timelockFactory));
    }

    function _liquidityMigratorData(
        MigratorKind migratorKind,
        ProceedsSplitKind proceedsSplitKind
    ) internal pure returns (bytes memory) {
        if (migratorKind == MigratorKind.NoOp) return new bytes(0);
        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) {
            return abi.encode(_proceedsRecipient(proceedsSplitKind), _proceedsShare(proceedsSplitKind));
        }
        return _dopplerHookMigratorData(proceedsSplitKind);
    }

    function _tokenFactoryData(
        BalanceLimitKind balanceLimitKind,
        address[] memory excludedFromBalanceLimit
    ) internal view returns (bytes memory) {
        (uint256 maxBalanceLimit, uint48 balanceLimitEnd) = _balanceLimitConfig(balanceLimitKind);

        return abi.encode(
            "Benchmark Token",
            "BENCH",
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "TOKEN_URI",
            maxBalanceLimit,
            balanceLimitEnd,
            address(0),
            excludedFromBalanceLimit
        );
    }

    function _balanceLimitConfig(BalanceLimitKind balanceLimitKind)
        internal
        view
        returns (uint256 maxBalanceLimit, uint48 balanceLimitEnd)
    {
        if (balanceLimitKind == BalanceLimitKind.Disabled) return (0, 0);
        return (MAX_BALANCE_LIMIT, uint48(block.timestamp + 30 days));
    }

    function _proceedsRecipient(ProceedsSplitKind proceedsSplitKind) internal pure returns (address) {
        if (proceedsSplitKind == ProceedsSplitKind.Enabled) return PROCEEDS_RECIPIENT;
        return address(0);
    }

    function _proceedsShare(ProceedsSplitKind proceedsSplitKind) internal pure returns (uint256) {
        if (proceedsSplitKind == ProceedsSplitKind.Enabled) return PROCEEDS_SHARE;
        return 0;
    }

    function _uniswapV4InitializerData() internal view returns (bytes memory) {
        return abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 1 days,
            int24(6000),
            int24(60_000),
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            10,
            uint24(0),
            int24(8)
        );
    }

    function _dopplerHookInitializerData() internal pure returns (bytes memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: WAD });

        return abi.encode(
            InitData({
                fee: 0,
                tickSpacing: 8,
                curves: curves,
                beneficiaries: new BeneficiaryData[](0),
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: new bytes(0),
                graduationDopplerHookCalldata: new bytes(0),
                farTick: 160_000
            })
        );
    }

    function _lockableV3InitializerData(address asset) internal pure returns (bytes memory) {
        bool isToken0 = asset < WETH_MAINNET;

        return abi.encode(
            LockableV3InitData({
                fee: 3000,
                tickLower: isToken0 ? int24(-200_040) : int24(167_520),
                tickUpper: isToken0 ? int24(-167_520) : int24(200_040),
                numPositions: 10,
                maxShareToBeSold: 0.23 ether,
                beneficiaries: new BeneficiaryData[](0)
            })
        );
    }

    function _dopplerHookMigratorData(ProceedsSplitKind proceedsSplitKind) internal pure returns (bytes memory) {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1111), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        return abi.encode(
            uint24(3000),
            false,
            int24(8),
            uint32(30 days),
            beneficiaries,
            address(0),
            new bytes(0),
            _proceedsRecipient(proceedsSplitKind),
            _proceedsShare(proceedsSplitKind)
        );
    }

    function _buyUntilDynamicV4CanMigrate(address hook) internal {
        bool canMigrate;
        uint256 i;

        do {
            address buyer = address(uint160(0x1000 + i));
            uint256 swapAmount = 0.01 ether;
            deal(buyer, swapAmount);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(hook)).poolKey();

            vm.prank(buyer);
            swapRouter.swap{ value: swapAmount }(
                PoolKey({
                    currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing
                }),
                IPoolManager.SwapParams(true, -int256(swapAmount), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            canMigrate = totalProceeds > Doppler(payable(hook)).minimumProceeds();

            i++;
            require(i < 100_000, "dynamic v4 cannot migrate");
        } while (!canMigrate);

        vm.warp(block.timestamp + 1 days);
    }

    function _buyUntilLockableV3CanMigrate(address pool, address asset) internal {
        bool isToken0 = asset < WETH_MAINNET;
        int24 targetTick = isToken0 ? int24(-167_520) : int24(167_520);
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(isToken0 ? targetTick + 60 : targetTick - 60);

        deal(address(this), 100_000 ether);
        WETH(payable(WETH_MAINNET)).deposit{ value: 100_000 ether }();
        WETH(payable(WETH_MAINNET)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_MAINNET,
                tokenOut: asset,
                fee: 3000,
                recipient: address(0x666),
                deadline: block.timestamp,
                amountIn: 1000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
            );

        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        if (isToken0) {
            assertGt(currentTick, targetTick, "current tick below far tick");
        } else {
            assertLt(currentTick, targetTick, "current tick above far tick");
        }
    }

    function _swapOnDopplerHookInitializerPool(address asset) internal {
        (,,,, PoolStatus status, PoolKey memory poolKey,) = dopplerHookInitializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));

        address buyer = address(0xCAFE);
        uint256 swapAmount = 0.1 ether;
        deal(buyer, swapAmount);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(buyer);
        swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _mineV4DopplerERC20V1(bytes memory poolInitializerData)
        internal
        returns (bytes32 salt, address hook, address asset)
    {
        (
            uint256 minimumProceeds,
            uint256 maximumProceeds,
            uint256 startingTime,
            uint256 endingTime,
            int24 startingTick,
            int24 endingTick,
            uint256 epochLength,
            int24 gamma,
            bool isToken0,
            uint256 numPDSlugs,
            uint24 lpFee,
        ) = abi.decode(
            poolInitializerData,
            (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
        );

        bytes32 dopplerInitHash = keccak256(
            abi.encodePacked(
                type(Doppler).creationCode,
                abi.encode(
                    address(manager),
                    NUM_TOKENS_TO_SELL,
                    minimumProceeds,
                    maximumProceeds,
                    startingTime,
                    endingTime,
                    startingTick,
                    endingTick,
                    epochLength,
                    gamma,
                    isToken0,
                    numPDSlugs,
                    uniswapV4Initializer,
                    lpFee
                )
            )
        );
        bytes32 tokenInitHash = LibClone.initCodeHash(tokenFactory.IMPLEMENTATION());
        address deployer = address(uniswapV4Initializer.deployer());

        for (uint256 seed = v4SaltCursor; seed < 200_000; ++seed) {
            hook = vm.computeCreate2Address(bytes32(seed), dopplerInitHash, deployer);
            asset = vm.computeCreate2Address(bytes32(seed), tokenInitHash, address(tokenFactory));

            if (
                uint160(hook) & Hooks.ALL_HOOK_MASK
                        == uint160(
                            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                        ) && hook.code.length == 0 && !isToken0 && asset > address(0)
            ) {
                v4SaltCursor = seed + 1;
                return (bytes32(seed), hook, asset);
            }
        }

        revert("GasBenchmark: could not find salt");
    }

    function _predictAsset(bytes32 salt) internal view returns (address) {
        return LibClone.predictDeterministicAddress(tokenFactory.IMPLEMENTATION(), salt, address(tokenFactory));
    }

    function _computeV3Pool(address asset, address numeraire, uint24 fee) internal pure returns (address) {
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            UNISWAP_V3_FACTORY_MAINNET,
                            keccak256(abi.encode(token0, token1, fee)),
                            UNISWAP_V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function _deployDopplerHookInitializer() internal returns (DopplerHookInitializer initializer) {
        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));
    }

    function _snapshotName() internal view returns (string memory) {
        return string.concat(_scenarioName(), "_", _featureName());
    }

    function _scenarioName() internal view returns (string memory) {
        return string.concat(
            _launchName(currentLaunchKind),
            "_",
            _initializerName(currentLaunchKind),
            "_",
            _migratorName(currentMigratorKind),
            "_",
            _governanceName(currentGovernanceKind)
        );
    }

    function _featureName() internal view returns (string memory) {
        return
            string.concat(_balanceLimitName(currentBalanceLimitKind), "_", _proceedsSplitName(currentProceedsSplitKind));
    }

    function _launchName(LaunchKind launchKind) internal pure returns (string memory) {
        if (launchKind == LaunchKind.Static) return "Static";
        if (launchKind == LaunchKind.Dynamic) return "Dynamic";
        return "Multicurve";
    }

    function _initializerName(LaunchKind launchKind) internal pure returns (string memory) {
        if (launchKind == LaunchKind.Static) return "LockableUniswapV3Initializer";
        if (launchKind == LaunchKind.Dynamic) return "UniswapV4Initializer";
        return "DopplerHookInitializer";
    }

    function _migratorName(MigratorKind migratorKind) internal pure returns (string memory) {
        if (migratorKind == MigratorKind.NoOp) return "NoOpMigrator";
        if (migratorKind == MigratorKind.UniswapV2MigratorSplit) return "UniswapV2MigratorSplit";
        return "DopplerHookMigrator";
    }

    function _governanceName(GovernanceKind governanceKind) internal pure returns (string memory) {
        if (governanceKind == GovernanceKind.NoOpGovernanceFactory) return "NoOpGovernanceFactory";
        if (governanceKind == GovernanceKind.LaunchpadGovernanceFactory) return "LaunchpadGovernanceFactory";
        return "GovernanceFactory";
    }

    function _balanceLimitName(BalanceLimitKind balanceLimitKind) internal pure returns (string memory) {
        if (balanceLimitKind == BalanceLimitKind.Disabled) return "BalanceLimitDisabled";
        if (balanceLimitKind == BalanceLimitKind.Exempt) return "BalanceLimitExempt";
        return "BalanceLimitApplied";
    }

    function _proceedsSplitName(ProceedsSplitKind proceedsSplitKind) internal pure returns (string memory) {
        if (proceedsSplitKind == ProceedsSplitKind.Enabled) return "ProceedsSplitEnabled";
        return "ProceedsSplitDisabled";
    }
}
