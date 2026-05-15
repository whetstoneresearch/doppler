// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import {
    InitData as LockableV3InitData,
    LockableUniswapV3Initializer
} from "src/initializers/LockableUniswapV3Initializer.sol";
import { UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DopplerHookMigrator, PoolStatus as MigratorStatus } from "src/migrators/DopplerHookMigrator.sol";
import { IUniswapV2Factory, UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import { BalanceLimitExceeded, DopplerERC20V1, VestingSchedule } from "src/tokens/DopplerERC20V1.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import {
    deployGovernanceFactory,
    deployUniswapV2,
    deployWeth,
    prepareGovernanceFactoryData
} from "test/integration/BaseIntegrationTest.sol";
import { deployDopplerHookMulticurveInitializer } from "test/integration/DopplerHookInitializer.t.sol";
import {
    DEFAULT_END_TICK,
    DEFAULT_FEE,
    DEFAULT_START_TICK,
    DEFAULT_TICK_SPACING,
    deployUniswapV4Initializer
} from "test/integration/UniswapV4Initializer.t.sol";
import {
    UNISWAP_V2_FACTORY_MAINNET,
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

contract DopplerERC20V1MaxBalanceIntegrationTest is Deployers, DeployPermit2 {
    uint256 internal constant INITIAL_SUPPLY = 1e23;
    uint256 internal constant NUM_TOKENS_TO_SELL = 1e23;
    uint256 internal constant MAX_BALANCE_LIMIT = 5e22;
    address internal constant AIRLOCK_OWNER = address(0xA111);
    address internal constant UNNECESSARY_EXCLUSION = address(0xB0B);
    bytes4 internal constant TRANSFER_FROM_FAILED_SELECTOR = bytes4(keccak256("TransferFromFailed()"));
    bytes4 internal constant WRAPPED_ERROR_SELECTOR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));
    bytes32 internal constant UNISWAP_V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    Airlock public airlock;
    DopplerERC20V1Factory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV4Initializer public uniswapV4Initializer;
    DopplerHookInitializer public dopplerHookInitializer;
    LockableUniswapV3Initializer public lockableV3Initializer;
    StreamableFeesLockerV2 public hookMigratorLocker;
    DopplerHookMigrator public hookMigrator;
    TopUpDistributor public splitTopUpDistributor;
    address public splitWeth;
    address public splitV2Factory;
    UniswapV2MigratorSplit public v2Migrator;
    IAllowanceTransfer public permit2;
    PositionManager public positionManager;
    StreamableFeesLocker public v4MigratorLocker;
    UniswapV4MigratorSplitHook public v4MigratorHook;
    UniswapV4MigratorSplit public v4Migrator;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(AIRLOCK_OWNER);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = deployGovernanceFactory(vm, airlock, AIRLOCK_OWNER);

        (, uniswapV4Initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        dopplerHookInitializer =
            deployDopplerHookMulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        lockableV3Initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));

        TopUpDistributor topUpDistributor = new TopUpDistributor(address(airlock));
        hookMigratorLocker = new StreamableFeesLockerV2(IPoolManager(address(manager)), AIRLOCK_OWNER);
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
            abi.encode(address(airlock), address(manager), hookMigratorLocker, topUpDistributor),
            address(hookMigrator)
        );

        splitTopUpDistributor = new TopUpDistributor(address(airlock));
        splitWeth = deployWeth();
        (splitV2Factory,) = deployUniswapV2(vm, splitWeth);
        v2Migrator = new UniswapV2MigratorSplit(
            address(airlock), IUniswapV2Factory(splitV2Factory), splitTopUpDistributor, splitWeth
        );
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = PositionManager(
            payable(address(
                    Deploy.positionManager(
                        address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
                    )
                ))
        );
        v4MigratorLocker = new StreamableFeesLocker(IPositionManager(address(positionManager)), AIRLOCK_OWNER);
        v4MigratorHook = UniswapV4MigratorSplitHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        v4Migrator = new UniswapV4MigratorSplit(
            address(airlock),
            IPoolManager(address(manager)),
            positionManager,
            v4MigratorLocker,
            IHooks(v4MigratorHook),
            splitTopUpDistributor
        );
        deployCodeTo(
            "UniswapV4MigratorSplitHook", abi.encode(address(manager), address(v4Migrator)), address(v4MigratorHook)
        );

        address[] memory modules = new address[](8);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV4Initializer);
        modules[2] = address(dopplerHookInitializer);
        modules[3] = address(lockableV3Initializer);
        modules[4] = address(hookMigrator);
        modules[5] = address(v2Migrator);
        modules[6] = address(v4Migrator);
        modules[7] = address(governanceFactory);

        ModuleState[] memory states = new ModuleState[](8);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.PoolInitializer;
        states[4] = ModuleState.LiquidityMigrator;
        states[5] = ModuleState.LiquidityMigrator;
        states[6] = ModuleState.LiquidityMigrator;
        states[7] = ModuleState.GovernanceFactory;

        vm.startPrank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
        hookMigratorLocker.approveMigrator(address(hookMigrator));
        v4MigratorLocker.approveMigrator(address(v4Migrator));
        topUpDistributor.setPullUp(address(hookMigrator), true);
        splitTopUpDistributor.setPullUp(address(v2Migrator), true);
        splitTopUpDistributor.setPullUp(address(v4Migrator), true);
        vm.stopPrank();
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_MigratesWithRequiredExclusions() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook, address predictedAsset) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](4);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(hookMigrator);
        excludedFromBalanceLimit[2] = address(hookMigratorLocker);
        excludedFromBalanceLimit[3] = address(manager);

        (address asset, address pool,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: NUM_TOKENS_TO_SELL,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: _tokenFactoryData(excludedFromBalanceLimit),
                governanceFactory: governanceFactory,
                governanceFactoryData: prepareGovernanceFactoryData(),
                poolInitializer: uniswapV4Initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: hookMigrator,
                liquidityMigratorData: _dopplerHookMigratorData(),
                integrator: address(0),
                salt: salt
            })
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, dopplerHook, "doppler hook prediction mismatch");
        _assertActiveLimit(token);
        assertTrue(token.isExcludedFromBalanceLimit(dopplerHook), "Doppler hook should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(hookMigrator)), "hook migrator should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(hookMigratorLocker)), "locker should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(manager)), "PoolManager should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(address(uniswapV4Initializer)), "initializer should be redundant");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilDynamicV4CanMigrate(dopplerHook);
        airlock.migrate(asset);

        (,,,,,,, MigratorStatus status) = hookMigrator.getAssetData(address(0), asset);
        assertEq(uint8(status), uint8(MigratorStatus.Locked), "migration pool should be locked");
        _swapOnMigrationPoolFor(asset, address(0));
        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_RevertsWithoutDynamicHookExclusion() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt,,) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = address(hookMigrator);
        excludedFromBalanceLimit[1] = address(hookMigratorLocker);
        excludedFromBalanceLimit[2] = address(manager);

        vm.expectRevert(TRANSFER_FROM_FAILED_SELECTOR);
        _create(
            salt,
            excludedFromBalanceLimit,
            uniswapV4Initializer,
            poolInitializerData,
            hookMigrator,
            _dopplerHookMigratorData()
        );
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_RevertsWithoutMigratorExclusion() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook,) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](2);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(manager);

        (address asset, address pool,,,) = airlock.create(
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: NUM_TOKENS_TO_SELL,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: _tokenFactoryData(excludedFromBalanceLimit),
                governanceFactory: governanceFactory,
                governanceFactoryData: prepareGovernanceFactoryData(),
                poolInitializer: uniswapV4Initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: hookMigrator,
                liquidityMigratorData: _dopplerHookMigratorData(),
                integrator: address(0),
                salt: salt
            })
        );

        _buyUntilDynamicV4CanMigrate(pool);

        vm.expectRevert(bytes("TRANSFER_FAILED"));
        airlock.migrate(asset);
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_RevertsWithoutHookMigratorLockerExclusion() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook,) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(hookMigrator);
        excludedFromBalanceLimit[2] = address(manager);

        (address asset, address pool,,,) = _create(
            salt,
            excludedFromBalanceLimit,
            uniswapV4Initializer,
            poolInitializerData,
            hookMigrator,
            _dopplerHookMigratorData()
        );

        _buyUntilDynamicV4CanMigrate(pool);

        vm.expectPartialRevert(WRAPPED_ERROR_SELECTOR);
        airlock.migrate(asset);
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_V2MigratorSplitMigratesWithRequiredExclusions() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook, address predictedAsset) = _mineV4DopplerERC20V1(poolInitializerData);
        address v2Pair = _createV2Pair(predictedAsset, splitWeth);

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(manager);
        excludedFromBalanceLimit[2] = address(v2Migrator);

        (address asset, address pool,, address timelock, address migrationPool) = _create(
            salt, excludedFromBalanceLimit, uniswapV4Initializer, poolInitializerData, v2Migrator, _v2MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, dopplerHook, "doppler hook prediction mismatch");
        assertEq(migrationPool, v2Pair, "migration pair mismatch");
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(token.isExcludedFromBalanceLimit(v2Pair), "migration pair should be auto-excluded by lockPool");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(address(uniswapV4Initializer)), "initializer should be redundant");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilDynamicV4CanMigrate(dopplerHook);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
        assertGt(DopplerERC20V1(asset).balanceOf(v2Pair), 0, "pair should receive migrated asset");
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_RevertsWithoutV2SplitMigratorExclusion() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook, address predictedAsset) = _mineV4DopplerERC20V1(poolInitializerData);
        address v2Pair = _createV2Pair(predictedAsset, splitWeth);

        address[] memory excludedFromBalanceLimit = new address[](2);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(manager);

        (address asset, address pool,, address timelock, address migrationPool) = _create(
            salt, excludedFromBalanceLimit, uniswapV4Initializer, poolInitializerData, v2Migrator, _v2MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, dopplerHook, "doppler hook prediction mismatch");
        assertEq(migrationPool, v2Pair, "migration pair mismatch");
        _assertActiveLimit(token);
        assertTrue(token.isExcludedFromBalanceLimit(dopplerHook), "Doppler hook should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(manager)), "PoolManager should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(v2Pair), "migration pair should be auto-excluded by lockPool");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(address(v2Migrator)), "v2 migrator should not be excluded");
        assertFalse(token.isExcludedFromBalanceLimit(address(uniswapV4Initializer)), "initializer should be redundant");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilDynamicV4CanMigrate(dopplerHook);

        vm.expectRevert(bytes("TRANSFER_FAILED"));
        airlock.migrate(asset);
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_V4MigratorSplitMigratesWithRequiredExclusions() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook,) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(manager);
        excludedFromBalanceLimit[2] = address(v4Migrator);

        (address asset,,, address timelock,) = _create(
            salt, excludedFromBalanceLimit, uniswapV4Initializer, poolInitializerData, v4Migrator, _v4MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(
            token.isExcludedFromBalanceLimit(address(0)), "empty migration pool should be auto-excluded by lockPool"
        );
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(address(uniswapV4Initializer)), "initializer should be redundant");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilDynamicV4CanMigrate(dopplerHook);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
        assertGt(positionManager.balanceOf(address(v4MigratorLocker)), 0, "locker should receive migrated liquidity");
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_RevertsWithoutV4SplitMigratorExclusion() public {
        bytes memory poolInitializerData = _uniswapV4InitializerData();
        (bytes32 salt, address dopplerHook,) = _mineV4DopplerERC20V1(poolInitializerData);

        address[] memory excludedFromBalanceLimit = new address[](2);
        excludedFromBalanceLimit[0] = dopplerHook;
        excludedFromBalanceLimit[1] = address(manager);

        (address asset, address pool,,,) = _create(
            salt, excludedFromBalanceLimit, uniswapV4Initializer, poolInitializerData, v4Migrator, _v4MigratorData()
        );

        _buyUntilDynamicV4CanMigrate(pool);

        vm.expectRevert(bytes("TRANSFER_FAILED"));
        airlock.migrate(asset);
    }

    function test_uniswapV4Initializer_V1ActiveMaxBalance_VestingBeneficiaryAutoExcludedAndCanReleaseAboveCap() public {
        address beneficiary = address(0xF00D);
        uint256 vestedAmount = MAX_BALANCE_LIMIT + 1;
        bytes32 salt = bytes32(uint256(31));

        address[] memory excludedFromBalanceLimit = new address[](0);
        bytes memory tokenFactoryData =
            _tokenFactoryDataWithVesting(excludedFromBalanceLimit, beneficiary, vestedAmount);

        vm.prank(address(airlock));
        address asset = tokenFactory.create(INITIAL_SUPPLY, address(airlock), address(airlock), salt, tokenFactoryData);

        DopplerERC20V1 token = DopplerERC20V1(asset);
        _assertActiveLimit(token);
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertTrue(token.isExcludedFromBalanceLimit(beneficiary), "vesting beneficiary should be auto-excluded");
        assertEq(token.balanceOf(beneficiary), 0, "beneficiary should not receive tokens before release");

        vm.warp(block.timestamp + 1 days);
        token.releaseFor(beneficiary, 0);

        assertEq(token.balanceOf(beneficiary), vestedAmount, "beneficiary should release above cap");
    }

    function test_dopplerHookInitializer_V1ActiveMaxBalance_MigratesWithRequiredExclusions() public {
        bytes32 salt = bytes32(uint256(1));
        address predictedAsset =
            LibClone.predictDeterministicAddress(tokenFactory.IMPLEMENTATION(), salt, address(tokenFactory));

        address[] memory excludedFromBalanceLimit = new address[](4);
        excludedFromBalanceLimit[0] = address(dopplerHookInitializer);
        excludedFromBalanceLimit[1] = address(hookMigrator);
        excludedFromBalanceLimit[2] = address(hookMigratorLocker);
        excludedFromBalanceLimit[3] = address(manager);

        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: NUM_TOKENS_TO_SELL,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: _tokenFactoryData(excludedFromBalanceLimit),
                governanceFactory: governanceFactory,
                governanceFactoryData: prepareGovernanceFactoryData(),
                poolInitializer: dopplerHookInitializer,
                poolInitializerData: _dopplerHookInitializerData(),
                liquidityMigrator: hookMigrator,
                liquidityMigratorData: _dopplerHookMigratorData(),
                integrator: address(0),
                salt: salt
            })
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        _assertActiveLimit(token);
        assertTrue(token.isExcludedFromBalanceLimit(address(dopplerHookInitializer)), "initializer should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(hookMigrator)), "hook migrator should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(hookMigratorLocker)), "locker should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(manager)), "PoolManager should be excluded");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _swapOnDopplerHookInitializerPool(asset);
        airlock.migrate(asset);

        (,,,,,,, MigratorStatus status) = hookMigrator.getAssetData(address(0), asset);
        assertEq(uint8(status), uint8(MigratorStatus.Locked), "migration pool should be locked");
        _swapOnMigrationPoolFor(asset, address(0));
        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
    }

    function test_dopplerHookInitializer_V1ActiveMaxBalance_RevertsWithoutInitializerExclusion() public {
        bytes32 salt = bytes32(uint256(2));

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = address(hookMigrator);
        excludedFromBalanceLimit[1] = address(hookMigratorLocker);
        excludedFromBalanceLimit[2] = address(manager);

        vm.expectRevert(TRANSFER_FROM_FAILED_SELECTOR);
        _create(
            salt,
            excludedFromBalanceLimit,
            dopplerHookInitializer,
            _dopplerHookInitializerData(),
            hookMigrator,
            _dopplerHookMigratorData()
        );
    }

    function test_dopplerHookInitializer_V1ActiveMaxBalance_RevertsWithoutPoolManagerExclusion() public {
        bytes32 salt = bytes32(uint256(3));

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = address(dopplerHookInitializer);
        excludedFromBalanceLimit[1] = address(hookMigrator);
        excludedFromBalanceLimit[2] = address(hookMigratorLocker);

        vm.expectPartialRevert(WRAPPED_ERROR_SELECTOR);
        _create(
            salt,
            excludedFromBalanceLimit,
            dopplerHookInitializer,
            _dopplerHookInitializerData(),
            hookMigrator,
            _dopplerHookMigratorData()
        );
    }

    function test_dopplerHookInitializer_V1ActiveMaxBalance_V2MigratorSplitMigratesWithRequiredExclusions() public {
        bytes32 salt = bytes32(uint256(11));
        address predictedAsset = _predictAsset(salt);
        address v2Pair = _createV2Pair(predictedAsset, splitWeth);

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = address(dopplerHookInitializer);
        excludedFromBalanceLimit[1] = address(manager);
        excludedFromBalanceLimit[2] = address(v2Migrator);

        (address asset,,, address timelock, address migrationPool) = _create(
            salt,
            excludedFromBalanceLimit,
            dopplerHookInitializer,
            _dopplerHookInitializerData(),
            v2Migrator,
            _v2MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(migrationPool, v2Pair, "migration pair mismatch");
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(token.isExcludedFromBalanceLimit(v2Pair), "migration pair should be auto-excluded by lockPool");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _swapOnDopplerHookInitializerPool(asset);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
        assertGt(DopplerERC20V1(asset).balanceOf(v2Pair), 0, "pair should receive migrated asset");
    }

    function test_dopplerHookInitializer_V1ActiveMaxBalance_V4MigratorSplitMigratesWithRequiredExclusions() public {
        bytes32 salt = bytes32(uint256(12));

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = address(dopplerHookInitializer);
        excludedFromBalanceLimit[1] = address(manager);
        excludedFromBalanceLimit[2] = address(v4Migrator);

        (address asset,,, address timelock,) = _create(
            salt,
            excludedFromBalanceLimit,
            dopplerHookInitializer,
            _dopplerHookInitializerData(),
            v4Migrator,
            _v4MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(
            token.isExcludedFromBalanceLimit(address(0)), "empty migration pool should be auto-excluded by lockPool"
        );
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _swapOnDopplerHookInitializerPool(asset);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), timelock, "owner should transfer to timelock");
        assertTrue(token.isExcludedFromBalanceLimit(timelock), "timelock should be auto-excluded on ownership transfer");
        assertGt(positionManager.balanceOf(address(v4MigratorLocker)), 0, "locker should receive migrated liquidity");
    }

    function test_lockableUniswapV3Initializer_V1ActiveMaxBalance_V2MigratorSplitMigratesWithRequiredExclusions()
        public
    {
        _resetOnMainnetFork();

        bytes32 salt = bytes32(uint256(21));
        address predictedAsset = _predictAsset(salt);
        address v3Pool = _computeV3Pool(predictedAsset, WETH_MAINNET, 3000);
        address v2Pair = _createMainnetV2Pair(predictedAsset, WETH_MAINNET);
        address timelock = _predictTimelock();
        UniswapV2MigratorSplit mainnetV2Migrator = _mainnetV2Migrator();

        address[] memory excludedFromBalanceLimit = new address[](3);
        excludedFromBalanceLimit[0] = v3Pool;
        excludedFromBalanceLimit[1] = address(mainnetV2Migrator);
        excludedFromBalanceLimit[2] = timelock;

        (address asset, address pool,, address actualTimelock, address migrationPool) = _createWithNumeraire(
            salt,
            WETH_MAINNET,
            excludedFromBalanceLimit,
            lockableV3Initializer,
            _lockableV3InitializerData(predictedAsset),
            mainnetV2Migrator,
            _v2MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, v3Pool, "v3 pool prediction mismatch");
        assertEq(migrationPool, v2Pair, "migration pair mismatch");
        assertEq(actualTimelock, timelock, "timelock prediction mismatch");
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(token.isExcludedFromBalanceLimit(v2Pair), "migration pair should be auto-excluded by lockPool");
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilLockableV3CanMigrate(pool, asset);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), actualTimelock, "owner should transfer to timelock");
        assertGt(DopplerERC20V1(asset).balanceOf(v2Pair), 0, "pair should receive migrated asset");
    }

    function test_lockableUniswapV3Initializer_V1ActiveMaxBalance_DopplerHookMigratorMigratesWithRequiredExclusions()
        public
    {
        _resetOnMainnetFork();

        bytes32 salt = bytes32(uint256(23));
        address predictedAsset = _predictAsset(salt);
        address v3Pool = _computeV3Pool(predictedAsset, WETH_MAINNET, 3000);
        address timelock = _predictTimelock();

        address[] memory excludedFromBalanceLimit = new address[](5);
        excludedFromBalanceLimit[0] = v3Pool;
        excludedFromBalanceLimit[1] = address(hookMigrator);
        excludedFromBalanceLimit[2] = address(hookMigratorLocker);
        excludedFromBalanceLimit[3] = address(manager);
        excludedFromBalanceLimit[4] = timelock;

        (address asset, address pool,, address actualTimelock,) = _createWithNumeraire(
            salt,
            WETH_MAINNET,
            excludedFromBalanceLimit,
            lockableV3Initializer,
            _lockableV3InitializerData(predictedAsset),
            hookMigrator,
            _dopplerHookMigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, v3Pool, "v3 pool prediction mismatch");
        assertEq(actualTimelock, timelock, "timelock prediction mismatch");
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(
            token.isExcludedFromBalanceLimit(address(0)), "empty migration pool should be auto-excluded by lockPool"
        );
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilLockableV3CanMigrate(pool, asset);
        airlock.migrate(asset);

        (,,,,,,, MigratorStatus status) = hookMigrator.getAssetData(
            WETH_MAINNET < asset ? WETH_MAINNET : asset, WETH_MAINNET < asset ? asset : WETH_MAINNET
        );
        assertEq(uint8(status), uint8(MigratorStatus.Locked), "migration pool should be locked");
        _swapOnMigrationPoolFor(asset, WETH_MAINNET);
        _assertActiveLimit(token);
        assertEq(token.owner(), actualTimelock, "owner should transfer to timelock");
        assertGt(token.balanceOf(address(hookMigratorLocker)), 0, "locker should receive migrated asset");
    }

    function test_lockableUniswapV3Initializer_V1ActiveMaxBalance_RevertsWithoutPoolExclusion() public {
        _resetOnMainnetFork();

        bytes32 salt = bytes32(uint256(24));
        address predictedAsset = _predictAsset(salt);
        address timelock = _predictTimelock();
        UniswapV2MigratorSplit mainnetV2Migrator = _mainnetV2Migrator();

        address[] memory excludedFromBalanceLimit = new address[](2);
        excludedFromBalanceLimit[0] = address(mainnetV2Migrator);
        excludedFromBalanceLimit[1] = timelock;

        (address asset, address pool,,,) = _createWithNumeraire(
            salt,
            WETH_MAINNET,
            excludedFromBalanceLimit,
            lockableV3Initializer,
            _lockableV3InitializerData(predictedAsset),
            mainnetV2Migrator,
            _v2MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        uint256 amountToExceedLimit = MAX_BALANCE_LIMIT - token.balanceOf(pool) + 1;

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(BalanceLimitExceeded.selector, MAX_BALANCE_LIMIT + 1, MAX_BALANCE_LIMIT));
        token.transfer(pool, amountToExceedLimit);
    }

    function test_lockableUniswapV3Initializer_V1ActiveMaxBalance_RevertsWithoutCreateTimeTimelockExclusion() public {
        _resetOnMainnetFork();

        bytes32 salt = bytes32(uint256(25));
        address predictedAsset = _predictAsset(salt);
        address v3Pool = _computeV3Pool(predictedAsset, WETH_MAINNET, 3000);
        UniswapV2MigratorSplit mainnetV2Migrator = _mainnetV2Migrator();

        address[] memory excludedFromBalanceLimit = new address[](2);
        excludedFromBalanceLimit[0] = v3Pool;
        excludedFromBalanceLimit[1] = address(mainnetV2Migrator);

        vm.expectRevert(bytes("TRANSFER_FAILED"));
        _createWithNumeraire(
            salt,
            WETH_MAINNET,
            excludedFromBalanceLimit,
            lockableV3Initializer,
            _lockableV3InitializerData(predictedAsset),
            mainnetV2Migrator,
            _v2MigratorData()
        );
    }

    function test_lockableUniswapV3Initializer_V1ActiveMaxBalance_V4MigratorSplitMigratesWithRequiredExclusions()
        public
    {
        _resetOnMainnetFork();

        bytes32 salt = bytes32(uint256(22));
        address predictedAsset = _predictAsset(salt);
        address v3Pool = _computeV3Pool(predictedAsset, WETH_MAINNET, 3000);
        address timelock = _predictTimelock();

        address[] memory excludedFromBalanceLimit = new address[](4);
        excludedFromBalanceLimit[0] = v3Pool;
        excludedFromBalanceLimit[1] = address(v4Migrator);
        excludedFromBalanceLimit[2] = address(manager);
        excludedFromBalanceLimit[3] = timelock;

        (address asset, address pool,, address actualTimelock,) = _createWithNumeraire(
            salt,
            WETH_MAINNET,
            excludedFromBalanceLimit,
            lockableV3Initializer,
            _lockableV3InitializerData(predictedAsset),
            v4Migrator,
            _v4MigratorData()
        );

        DopplerERC20V1 token = DopplerERC20V1(asset);
        assertEq(asset, predictedAsset, "asset prediction mismatch");
        assertEq(pool, v3Pool, "v3 pool prediction mismatch");
        assertEq(actualTimelock, timelock, "timelock prediction mismatch");
        _assertActiveLimit(token);
        _assertExcluded(token, excludedFromBalanceLimit);
        assertTrue(
            token.isExcludedFromBalanceLimit(address(0)), "empty migration pool should be auto-excluded by lockPool"
        );
        assertTrue(token.isExcludedFromBalanceLimit(address(airlock)), "Airlock should be auto-excluded");
        assertFalse(token.isExcludedFromBalanceLimit(UNNECESSARY_EXCLUSION), "unnecessary address excluded");

        _buyUntilLockableV3CanMigrate(pool, asset);
        airlock.migrate(asset);

        _assertActiveLimit(token);
        assertEq(token.owner(), actualTimelock, "owner should transfer to timelock");
        assertGt(positionManager.balanceOf(address(v4MigratorLocker)), 0, "locker should receive migrated liquidity");
    }

    function _tokenFactoryData(address[] memory excludedFromBalanceLimit) internal view returns (bytes memory) {
        return abi.encode(
            "Doppler V1 Max Balance Test",
            "DOPV1MAX",
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "TOKEN_URI",
            MAX_BALANCE_LIMIT,
            uint48(block.timestamp + 30 days),
            address(0),
            excludedFromBalanceLimit
        );
    }

    function _tokenFactoryDataWithVesting(
        address[] memory excludedFromBalanceLimit,
        address beneficiary,
        uint256 vestedAmount
    ) internal view returns (bytes memory) {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: 0, duration: 1 days });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = beneficiary;

        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = vestedAmount;

        return abi.encode(
            "Doppler V1 Max Balance Test",
            "DOPV1MAX",
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            "TOKEN_URI",
            MAX_BALANCE_LIMIT,
            uint48(block.timestamp + 30 days),
            address(0),
            excludedFromBalanceLimit
        );
    }

    function _uniswapV4InitializerData() internal view returns (bytes memory) {
        return abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 1 days,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            10,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );
    }

    function _mineV4DopplerERC20V1(bytes memory poolInitializerData)
        internal
        returns (bytes32 salt, address hook, address asset)
    {
        return _mineV4DopplerERC20V1(poolInitializerData, NUM_TOKENS_TO_SELL);
    }

    function _mineV4DopplerERC20V1(
        bytes memory poolInitializerData,
        uint256 numTokensToSell
    ) internal returns (bytes32 salt, address hook, address asset) {
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
                    numTokensToSell,
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

        for (uint256 seed; seed < 200_000; ++seed) {
            hook = vm.computeCreate2Address(bytes32(seed), dopplerInitHash, deployer);
            asset = vm.computeCreate2Address(bytes32(seed), tokenInitHash, address(tokenFactory));

            if (
                uint160(hook) & Hooks.ALL_HOOK_MASK
                        == uint160(
                            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                        ) && hook.code.length == 0
                    && ((isToken0 && asset < address(0)) || (!isToken0 && asset > address(0)))
            ) {
                return (bytes32(seed), hook, asset);
            }
        }

        revert("DopplerERC20V1MaxBalanceIntegration: could not find salt");
    }

    function _dopplerHookMigratorData() internal pure returns (bytes memory) {
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
            address(0),
            uint256(0)
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

    function _v2MigratorData() internal pure returns (bytes memory) {
        return abi.encode(address(0), uint256(0));
    }

    function _v4MigratorData() internal pure returns (bytes memory) {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xB0B), shares: 0.9e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: address(0xBEEF), shares: 0.05e18 });

        return abi.encode(uint24(2000), int24(8), uint32(30 days), beneficiaries, address(0), uint256(0));
    }

    function _resetOnMainnetFork() internal {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);
        setUp();
    }

    function _create(
        bytes32 salt,
        address[] memory excludedFromBalanceLimit,
        IPoolInitializer poolInitializer,
        bytes memory poolInitializerData,
        ILiquidityMigrator liquidityMigrator,
        bytes memory liquidityMigratorData
    ) internal returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        return _createWithNumeraire(
            salt,
            address(0),
            excludedFromBalanceLimit,
            poolInitializer,
            poolInitializerData,
            liquidityMigrator,
            liquidityMigratorData
        );
    }

    function _createWithNumeraire(
        bytes32 salt,
        address numeraire,
        address[] memory excludedFromBalanceLimit,
        IPoolInitializer poolInitializer,
        bytes memory poolInitializerData,
        ILiquidityMigrator liquidityMigrator,
        bytes memory liquidityMigratorData
    ) internal returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        return airlock.create(
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: NUM_TOKENS_TO_SELL,
                numeraire: numeraire,
                tokenFactory: tokenFactory,
                tokenFactoryData: _tokenFactoryData(excludedFromBalanceLimit),
                governanceFactory: governanceFactory,
                governanceFactoryData: prepareGovernanceFactoryData(),
                poolInitializer: poolInitializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: liquidityMigrator,
                liquidityMigratorData: liquidityMigratorData,
                integrator: address(0),
                salt: salt
            })
        );
    }

    function _predictAsset(bytes32 salt) internal view returns (address) {
        return LibClone.predictDeterministicAddress(tokenFactory.IMPLEMENTATION(), salt, address(tokenFactory));
    }

    function _predictTimelock() internal view returns (address) {
        address timelockFactory = address(governanceFactory.timelockFactory());
        return vm.computeCreateAddress(timelockFactory, vm.getNonce(timelockFactory));
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

    function _createV2Pair(address asset, address numeraire) internal returns (address pair) {
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;
        IUniswapV2Factory factory = IUniswapV2Factory(splitV2Factory);

        pair = factory.getPair(token0, token1);
        if (pair == address(0)) pair = factory.createPair(token0, token1);
    }

    function _createMainnetV2Pair(address asset, address numeraire) internal returns (address pair) {
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;
        IUniswapV2Factory factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET);

        pair = factory.getPair(token0, token1);
        if (pair == address(0)) pair = factory.createPair(token0, token1);
    }

    function _mainnetV2Migrator() internal returns (UniswapV2MigratorSplit migrator) {
        TopUpDistributor topUpDistributor = new TopUpDistributor(address(airlock));
        migrator = new UniswapV2MigratorSplit(
            address(airlock), IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET), topUpDistributor, WETH_MAINNET
        );

        address[] memory modules = new address[](1);
        modules[0] = address(migrator);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;

        vm.startPrank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
        topUpDistributor.setPullUp(address(migrator), true);
        vm.stopPrank();
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

    function _swapOnMigrationPoolFor(address asset, address numeraire) internal {
        (address currency0, address currency1) = numeraire < asset ? (numeraire, asset) : (asset, numeraire);
        (, PoolKey memory poolKey,,,,,, MigratorStatus status) = hookMigrator.getAssetData(currency0, currency1);
        assertEq(uint8(status), uint8(MigratorStatus.Locked), "migration pool should be locked");

        address buyer = address(0xBEEFCAFE);
        uint256 swapAmount = 0.1 ether;
        uint256 balanceBefore = DopplerERC20V1(asset).balanceOf(buyer);
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        if (numeraire == address(0)) {
            deal(buyer, swapAmount);
            vm.prank(buyer);
            swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
        } else {
            deal(numeraire, buyer, swapAmount);
            vm.startPrank(buyer);
            WETH(payable(numeraire)).approve(address(swapRouter), swapAmount);
            swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
            vm.stopPrank();
        }

        uint256 balanceAfter = DopplerERC20V1(asset).balanceOf(buyer);
        assertGt(balanceAfter, balanceBefore, "buyer should receive asset");
        if (DopplerERC20V1(asset).isBalanceLimitActive()) {
            assertLe(balanceAfter, MAX_BALANCE_LIMIT, "buyer should stay below max balance");
        }
    }

    function _assertActiveLimit(DopplerERC20V1 token) internal view {
        assertTrue(token.isBalanceLimitActive(), "balance limit should be active");
        assertEq(token.maxBalanceLimit(), MAX_BALANCE_LIMIT, "wrong max balance limit");
        assertGt(token.balanceLimitEnd(), block.timestamp, "balance limit should still be active");
    }

    function _assertExcluded(DopplerERC20V1 token, address[] memory excludedFromBalanceLimit) internal view {
        uint256 length = excludedFromBalanceLimit.length;
        for (uint256 i; i < length; ++i) {
            assertTrue(token.isExcludedFromBalanceLimit(excludedFromBalanceLimit[i]), "expected address excluded");
        }
    }

    function _deployCodeTo(string memory what, bytes memory args, address where) internal {
        deployCodeTo(what, args, where);
    }
}
