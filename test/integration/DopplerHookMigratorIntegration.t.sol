// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { ON_AFTER_SWAP_FLAG, ON_INITIALIZATION_FLAG } from "src/base/BaseDopplerHookMigrator.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
import { RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { InsufficientAmountLeft, SwapRestrictorDopplerHook } from "src/dopplerHooks/SwapRestrictorDopplerHook.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { LaunchpadGovernanceFactory } from "src/governance/LaunchpadGovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { StreamableFeesLockerV3 } from "src/lockers/StreamableFeesLockerV3.sol";
import {
    AssetData,
    DopplerHookMigrator,
    DopplerHookNotEnabled,
    PoolStatus as MigratorStatus
} from "src/migrators/DopplerHookMigrator.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";
import { FeeDistributionInfo, FeeRoutingMode, MigratorInitData as RehypeInitData } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";
import { dopplerERC20V1FactoryData } from "test/shared/DopplerERC20V1FactoryHelper.sol";

contract DopplerHookMigratorIntegrationTest is Deployers, DeployPermit2 {
    using StateLibrary for IPoolManager;
    address internal constant AIRLOCK_OWNER = address(0xA111);
    address internal constant BENEFICIARY_1 = address(0x1111);
    address internal constant PROCEEDS_RECIPIENT = address(0x5555);

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    DopplerERC20V1Factory public tokenFactory;
    NoOpGovernanceFactory public governanceFactory;
    StreamableFeesLockerV3 public locker;
    DopplerHookMigrator public migrator;
    TopUpDistributor public topUpDistributor;
    RehypeDopplerHookInitializer public rehypeHook;
    RehypeDopplerHookMigrator public rehypeHookMigrator;
    SwapRestrictorDopplerHook public swapRestrictorHook;
    IAllowanceTransfer public permit2;
    PositionManager public positionManager;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(AIRLOCK_OWNER);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = new NoOpGovernanceFactory();

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

        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = PositionManager(
            payable(address(
                    Deploy.positionManager(
                        address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
                    )
                ))
        );
        locker = new StreamableFeesLockerV3(IPoolManager(address(manager)), positionManager, AIRLOCK_OWNER);
        topUpDistributor = new TopUpDistributor(address(airlock));

        uint256 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address migratorHookAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorHookAddress));
        deployCodeTo(
            "DopplerHookMigrator",
            abi.encode(address(airlock), address(manager), locker, topUpDistributor),
            migratorHookAddress
        );

        rehypeHook = new RehypeDopplerHookInitializer(address(migrator), manager);
        rehypeHookMigrator = new RehypeDopplerHookMigrator(migrator, manager);
        swapRestrictorHook = new SwapRestrictorDopplerHook(address(migrator));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
        locker.approveMigrator(address(migrator));
        topUpDistributor.setPullUp(address(migrator), true);
        vm.stopPrank();
    }

    function test_fullFlow_CreateAndMigrate_FixedFee() public {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(1))
            })
        );

        (, PoolKey memory poolKey,,, bool useDynamicFee,,,) = migrator.getAssetData(address(0), asset);
        assertEq(address(poolKey.hooks), address(migrator));
        assertEq(useDynamicFee, false);

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (,,,,,,, MigratorStatus migratorStatus) = migrator.getAssetData(address(0), asset);
        assertEq(uint8(migratorStatus), uint8(MigratorStatus.Locked), "Pool should be Locked after migrate");

        (PoolKey memory streamKey, address recipient, uint32 startDate, uint32 lockDuration, bool isUnlocked) =
            locker.streams(poolKey.toId());
        assertEq(address(streamKey.hooks), address(migrator));
        assertEq(recipient, timelock);
        assertEq(lockDuration, 30 days);
        assertEq(isUnlocked, false);
        assertEq(startDate > 0, true);
    }

    function test_fullFlow_MigratingAnotherPoolDoesNotConsumeCollectedNativeFees() public {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address assetA,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(32))
            })
        );

        _swapOnInitializerPool(assetA);
        airlock.migrate(assetA);
        _swapOnMigrationPool(assetA);

        (, PoolKey memory poolKeyA,,,,,,) = migrator.getAssetData(address(0), assetA);
        assertEq(Currency.unwrap(poolKeyA.currency0), address(0), "native numeraire should be currency0");

        uint256 lockerNativeBeforeCollect = address(locker).balance;
        vm.prank(makeAddr("Harvester"));
        (uint128 feesA0, uint128 feesA1) = locker.collectFees(poolKeyA.toId());
        uint256 collectedNativeFees = address(locker).balance - lockerNativeBeforeCollect;

        assertGt(collectedNativeFees, 0, "test must collect native fees for pool A");
        assertEq(collectedNativeFees, feesA0, "pool A native fee delta mismatch");
        assertEq(feesA1, 0, "test only expects native-side fees");

        uint256 beneficiaryNativeBefore = BENEFICIARY_1.balance;
        uint256 expectedBeneficiaryClaim = collectedNativeFees * 95 / 100;
        uint256 lockerNativeBeforePoolBMigration = address(locker).balance;

        (address assetB,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(33))
            })
        );

        _swapOnInitializerPool(assetB);
        airlock.migrate(assetB);

        assertGe(
            address(locker).balance,
            lockerNativeBeforePoolBMigration,
            "pool B migration should not reduce pool A's held native fees"
        );

        vm.prank(BENEFICIARY_1);
        locker.collectFees(poolKeyA.toId());

        assertEq(BENEFICIARY_1.balance, beneficiaryNativeBefore + expectedBeneficiaryClaim);
    }

    function test_fullFlow_MigratingAnotherPoolDoesNotConsumeCollectedERC20NumeraireFees() public {
        Currency numeraireCurrency = deployMintAndApproveCurrency();
        address numeraire = Currency.unwrap(numeraireCurrency);
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address assetA,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: numeraire,
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(34))
            })
        );

        _swapOnInitializerPoolWithERC20Numeraire(assetA, numeraire);
        airlock.migrate(assetA);
        _swapOnMigrationPool(assetA);

        PoolKey memory poolKeyA = _migrationPoolKey(assetA);
        bool numeraireIsCurrency0 = Currency.unwrap(poolKeyA.currency0) == numeraire;
        assertTrue(numeraireIsCurrency0 || Currency.unwrap(poolKeyA.currency1) == numeraire, "numeraire missing");

        uint256 lockerNumeraireBeforeCollect = ERC20(numeraire).balanceOf(address(locker));
        vm.prank(makeAddr("Harvester"));
        (uint128 feesA0, uint128 feesA1) = locker.collectFees(poolKeyA.toId());
        uint256 collectedNumeraireFees = ERC20(numeraire).balanceOf(address(locker)) - lockerNumeraireBeforeCollect;
        uint128 collectedNumeraireFeesFromReturn = numeraireIsCurrency0 ? feesA0 : feesA1;

        assertGt(collectedNumeraireFees, 0, "test must collect numeraire fees for pool A");
        assertEq(collectedNumeraireFees, uint256(collectedNumeraireFeesFromReturn), "pool A fee delta mismatch");

        uint256 beneficiaryNumeraireBefore = ERC20(numeraire).balanceOf(BENEFICIARY_1);
        uint256 expectedBeneficiaryClaim = collectedNumeraireFees * 95 / 100;
        uint256 lockerNumeraireBeforePoolBMigration = ERC20(numeraire).balanceOf(address(locker));

        (address assetB,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: numeraire,
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(35))
            })
        );

        _swapOnInitializerPoolWithERC20Numeraire(assetB, numeraire);
        airlock.migrate(assetB);

        assertGe(
            ERC20(numeraire).balanceOf(address(locker)),
            lockerNumeraireBeforePoolBMigration,
            "pool B migration should not reduce pool A's held numeraire fees"
        );

        vm.prank(BENEFICIARY_1);
        locker.collectFees(poolKeyA.toId());

        assertEq(ERC20(numeraire).balanceOf(BENEFICIARY_1), beneficiaryNumeraireBefore + expectedBeneficiaryClaim);
    }

    function test_fullFlow_DustIsForwardedToLaunchpadGovernanceRecipient() public {
        LaunchpadGovernanceFactory launchpadGovernanceFactory = new LaunchpadGovernanceFactory();
        address[] memory modules = new address[](1);
        modules[0] = address(launchpadGovernanceFactory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.GovernanceFactory;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);

        address timelockRecipient = makeAddr("DustRecipient");

        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: _defaultTokenFactoryData(),
                governanceFactory: launchpadGovernanceFactory,
                governanceFactoryData: abi.encode(timelockRecipient),
                poolInitializer: initializer,
                poolInitializerData: _defaultPoolInitializerData(),
                liquidityMigrator: migrator,
                liquidityMigratorData: _defaultMigratorData(false, address(0), new bytes(0)),
                integrator: address(0),
                salt: bytes32(uint256(36))
            })
        );
        assertEq(timelock, timelockRecipient);

        uint256 recipientNativeBefore = timelockRecipient.balance;
        uint256 recipientAssetBefore = ERC20(asset).balanceOf(timelockRecipient);

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        PoolKey memory poolKey = _migrationPoolKey(asset);
        assertEq(Currency.unwrap(poolKey.currency0), address(0), "native numeraire should be currency0");
        assertEq(Currency.unwrap(poolKey.currency1), asset, "asset should be currency1");
        _assertNoFreeMigrationBalances(poolKey);

        assertGt(timelockRecipient.balance, recipientNativeBefore, "native dust should go to governance recipient");
        assertGt(
            ERC20(asset).balanceOf(timelockRecipient),
            recipientAssetBefore,
            "asset dust should go to governance recipient"
        );
    }

    function test_fullFlow_NoOpGovernance_DustAndFeeCollectionDoNotRevert() public {
        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: _defaultTokenFactoryData(),
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: _defaultPoolInitializerData(),
                liquidityMigrator: migrator,
                liquidityMigratorData: _defaultMigratorData(false, address(0), new bytes(0)),
                integrator: address(0),
                salt: bytes32(uint256(37))
            })
        );
        assertEq(timelock, DEAD_ADDRESS);

        uint256 deadNativeBefore = DEAD_ADDRESS.balance;
        uint256 deadAssetBefore = ERC20(asset).balanceOf(DEAD_ADDRESS);

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        PoolKey memory poolKey = _migrationPoolKey(asset);
        (, address recipient, uint32 startDate, uint32 lockDuration, bool isUnlocked) = locker.streams(poolKey.toId());
        assertEq(recipient, DEAD_ADDRESS);
        assertGt(startDate, 0);
        assertEq(lockDuration, 30 days);
        assertEq(isUnlocked, false);
        _assertNoFreeMigrationBalances(poolKey);
        assertGt(DEAD_ADDRESS.balance, deadNativeBefore, "native dust should go to dead recipient");
        assertGt(ERC20(asset).balanceOf(DEAD_ADDRESS), deadAssetBefore, "asset dust should go to dead recipient");

        _swapOnMigrationPool(asset);

        uint256 beneficiaryBalance0Before = poolKey.currency0.balanceOf(BENEFICIARY_1);
        uint256 beneficiaryBalance1Before = poolKey.currency1.balanceOf(BENEFICIARY_1);

        vm.prank(makeAddr("Harvester"));
        (uint128 fees0, uint128 fees1) = locker.collectFees(poolKey.toId());
        assertGt(uint256(fees0) + uint256(fees1), 0, "test should collect fees");

        vm.prank(BENEFICIARY_1);
        locker.collectFees(poolKey.toId());

        assertEq(
            poolKey.currency0.balanceOf(BENEFICIARY_1),
            beneficiaryBalance0Before + uint256(fees0) * 95 / 100,
            "beneficiary should receive currency0 fees"
        );
        assertEq(
            poolKey.currency1.balanceOf(BENEFICIARY_1),
            beneficiaryBalance1Before + uint256(fees1) * 95 / 100,
            "beneficiary should receive currency1 fees"
        );

        uint256[] memory tokenIds = locker.getTokenIds(poolKey.toId());
        assertGt(tokenIds.length, 0, "locker should mint position NFTs");

        vm.warp(uint256(startDate) + lockDuration);
        vm.prank(makeAddr("LateHarvester"));
        locker.collectFees(poolKey.toId());

        (,,,, bool isUnlockedAfterDuration) = locker.streams(poolKey.toId());
        assertEq(isUnlockedAfterDuration, false, "NoOp governance stream should remain permanently locked");
        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), address(locker), "locker should retain NFT for NoOp");
        }
    }

    function test_fullFlow_PostUnlockTransfersPositionNFTsToRecipient() public {
        LaunchpadGovernanceFactory launchpadGovernanceFactory = new LaunchpadGovernanceFactory();
        address[] memory modules = new address[](1);
        modules[0] = address(launchpadGovernanceFactory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.GovernanceFactory;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);

        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();
        address timelockRecipient = makeAddr("TimelockRecipient");

        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: launchpadGovernanceFactory,
                governanceFactoryData: abi.encode(timelockRecipient),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(30))
            })
        );
        assertEq(timelock, timelockRecipient);

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        (,, uint32 startDate, uint32 lockDuration, bool isUnlocked) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);
        assertEq(lockDuration, 30 days);
        assertEq(isUnlocked, false);

        uint256[] memory tokenIds = locker.getTokenIds(poolKey.toId());
        assertGt(tokenIds.length, 0, "locker should mint position NFTs");

        uint256 balance0Before = poolKey.currency0.balanceOf(timelock);
        uint256 balance1Before = poolKey.currency1.balanceOf(timelock);

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), address(locker), "locker should hold NFT before unlock");
            assertGt(positionManager.getPositionLiquidity(tokenIds[i]), 0, "position should have liquidity");
        }

        vm.warp(uint256(startDate) + lockDuration);
        locker.collectFees(poolKey.toId());

        assertEq(poolKey.currency0.balanceOf(timelock), balance0Before, "timelock should not receive raw currency0");
        assertEq(poolKey.currency1.balanceOf(timelock), balance1Before, "timelock should not receive raw currency1");

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), timelock, "timelock should receive position NFT");
            assertGt(positionManager.getPositionLiquidity(tokenIds[i]), 0, "liquidity should remain");
        }
    }

    function test_fullFlow_PostUnlockTransfersPositionNFTsToTimelockContract() public {
        GovernanceFactory timelockGovernanceFactory = new GovernanceFactory(address(airlock));
        address[] memory modules = new address[](1);
        modules[0] = address(timelockGovernanceFactory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.GovernanceFactory;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);

        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,, address timelock,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: timelockGovernanceFactory,
                governanceFactoryData: abi.encode("Test Token", uint48(7200), uint32(50_400), uint256(0)),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(31))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        (,, uint32 startDate, uint32 lockDuration, bool isUnlocked) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);
        assertEq(isUnlocked, false);

        uint256[] memory tokenIds = locker.getTokenIds(poolKey.toId());
        assertGt(tokenIds.length, 0, "locker should mint position NFTs");

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), address(locker), "locker should hold NFT before unlock");
        }

        vm.warp(uint256(startDate) + lockDuration);
        locker.collectFees(poolKey.toId());

        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(positionManager.ownerOf(tokenIds[i]), timelock, "timelock contract should receive position NFT");
            assertGt(positionManager.getPositionLiquidity(tokenIds[i]), 0, "liquidity should remain");
        }
    }

    function test_fullFlow_CreateAndMigrate_WithRehypeHook() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(rehypeHookMigrator);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        bytes memory rehypeData = abi.encode(
            RehypeInitData({
                numeraire: address(0),
                buybackDst: address(0xBEEF),
                customFee: 3000,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.2e18,
                    assetFeesToNumeraireBuybackWad: 0.2e18,
                    assetFeesToBeneficiaryWad: 0.3e18,
                    assetFeesToLpWad: 0.3e18,
                    numeraireFeesToAssetBuybackWad: 0.2e18,
                    numeraireFeesToNumeraireBuybackWad: 0.2e18,
                    numeraireFeesToBeneficiaryWad: 0.3e18,
                    numeraireFeesToLpWad: 0.3e18
                })
            })
        );
        bytes memory migratorData = _defaultMigratorData(false, address(rehypeHookMigrator), rehypeData);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: initData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(10))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        _swapOnMigrationPool(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeHookMigrator.getHookFees(poolKey.toId());
        assertTrue(
            beneficiaryFees0 + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1 > 0,
            "Rehype hook should accrue fees"
        );
    }

    function test_fullFlow_CreateAndMigrate_WithSwapRestrictorHook() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(swapRestrictorHook);
        flags[0] = ON_INITIALIZATION_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        address allowedBuyer = makeAddr("AllowedBuyer");
        address[] memory approved = new address[](1);
        approved[0] = allowedBuyer;
        bytes memory hookData = abi.encode(approved, uint256(1 ether));

        bytes memory initData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(swapRestrictorHook), hookData);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: initData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(12))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        assertEq(swapRestrictorHook.amountLeftOf(poolKey.toId(), allowedBuyer), 1 ether);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        BalanceDelta delta = toBalanceDelta(
            isToken0 ? int128(uint128(0.01 ether)) : int128(0), isToken0 ? int128(0) : int128(uint128(0.01 ether))
        );
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: 0
        });

        vm.prank(address(migrator));
        swapRestrictorHook.onSwap(allowedBuyer, poolKey, swapParams, delta, new bytes(0));

        assertLt(swapRestrictorHook.amountLeftOf(poolKey.toId(), allowedBuyer), 1 ether);

        address unapproved = makeAddr("Unapproved");
        vm.prank(address(migrator));
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientAmountLeft.selector, poolKey.toId(), unapproved, 0.01 ether, 0)
        );
        swapRestrictorHook.onSwap(unapproved, poolKey, swapParams, delta, new bytes(0));
    }

    function test_fullFlow_CreateAndMigrate_DynamicFee() public {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(true, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(3))
            })
        );

        (, PoolKey memory poolKey,,, bool useDynamicFee,,,) = migrator.getAssetData(address(0), asset);
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(useDynamicFee, true);

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 3000);
    }

    function test_fullFlow_CreateAndMigrate_CustomBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.9e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x2222), shares: 0.05e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData =
            _migratorDataWithBeneficiaries(false, address(0), new bytes(0), beneficiaries, 7 days);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,, address timelock,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(4))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        (, address recipient,, uint32 lockDuration, bool isUnlocked) = locker.streams(poolKey.toId());
        assertEq(recipient, timelock);
        assertEq(lockDuration, 7 days);
        assertEq(isUnlocked, false);
    }

    function test_fullFlow_CreateAndMigrate_TracksIntegratorFees() public {
        address integrator = address(0xBEEF);
        bytes memory poolInitializerData = _poolInitializerDataWithFee(3000);
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: integrator,
                salt: bytes32(uint256(5))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        uint256 protocolFees = airlock.getProtocolFees(address(0));
        uint256 integratorFees = airlock.getIntegratorFees(integrator, address(0));
        assertGt(protocolFees + integratorFees, 0);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_fullFlow_CreateAndMigrate_TickSpacing(uint256 tickSpacingSeed) public {
        int24 tickSpacing = int24(uint24(bound(tickSpacingSeed, 1, 100)));
        bytes memory poolInitializerData = _poolInitializerDataWithTickSpacing(tickSpacing);
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(6) ^ uint256(tickSpacingSeed))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);
    }

    function test_fullFlow_Migrate_RevertIfHookDisabledAfterInitialize() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(rehypeHookMigrator);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(rehypeHookMigrator), _defaultRehypeData());
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: initData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(7))
            })
        );

        flags[0] = 0;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        _swapOnInitializerPool(asset);
        vm.expectRevert(DopplerHookNotEnabled.selector);
        airlock.migrate(asset);
    }

    function testFuzz_fullFlow_CreateAndMigrate_SwapDirection(bool reverse) public {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(8))
            })
        );

        _swapOnInitializerPoolBidirectional(asset, reverse);
        airlock.migrate(asset);
    }

    function testFuzz_fullFlow_CreateAndMigrate_FeeTier(uint256 feeSeed) public {
        uint24 fee = _pickFeeTier(feeSeed);
        bytes memory poolInitializerData = _poolInitializerDataWithFee(fee);
        bytes memory migratorData = _defaultMigratorData(false, address(0), new bytes(0));
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(9) ^ uint256(feeSeed))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);
    }

    function test_fullFlow_CreateAndMigrateWithSplit() public {
        uint256 proceedsShare = 0.1e18; // 10%
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData =
            _splitMigratorData(false, address(0), new bytes(0), PROCEEDS_RECIPIENT, proceedsShare);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,, address timelock,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(20))
            })
        );

        // Verify split configuration was stored
        (address storedRecipient,, uint256 storedShare) = migrator.splitConfigurationOf(address(0), asset);
        assertEq(storedRecipient, PROCEEDS_RECIPIENT);
        assertEq(storedShare, proceedsShare);

        uint256 recipientBalanceBefore = PROCEEDS_RECIPIENT.balance;

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        {
            (,,,,,,, MigratorStatus migratorStatus) = migrator.getAssetData(address(0), asset);
            assertEq(uint8(migratorStatus), uint8(MigratorStatus.Locked), "Pool should be Locked after migrate");
        }

        // Verify the recipient received the split
        uint256 recipientBalanceAfter = PROCEEDS_RECIPIENT.balance;
        assertGt(recipientBalanceAfter - recipientBalanceBefore, 0, "Proceeds recipient should have received ETH");

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        (PoolKey memory streamKey, address streamRecipient, uint32 startDate, uint32 lockDuration, bool isUnlocked) =
            locker.streams(poolKey.toId());
        assertEq(address(streamKey.hooks), address(migrator));
        assertEq(streamRecipient, timelock);
        assertEq(lockDuration, 30 days);
        assertEq(isUnlocked, false);
        assertEq(startDate > 0, true);
    }

    function test_fullFlow_CreateAndMigrateWithoutSplit() public {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory migratorData = _splitMigratorData(false, address(0), new bytes(0), PROCEEDS_RECIPIENT, 0);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(21))
            })
        );

        uint256 recipientBalanceBefore = PROCEEDS_RECIPIENT.balance;

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        // Verify the recipient received nothing (no split)
        assertEq(PROCEEDS_RECIPIENT.balance, recipientBalanceBefore, "Proceeds recipient should not have received ETH");

        (, PoolKey memory poolKey,,,,,, MigratorStatus migratorStatus) = migrator.getAssetData(address(0), asset);
        assertEq(uint8(migratorStatus), uint8(MigratorStatus.Locked), "Pool should be Locked after migrate");
        (,, uint32 startDate,,) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);
    }

    function test_fullFlow_CreateAndMigrate_WithRehypeHookAndSplit() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(rehypeHookMigrator);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        uint24 customFee = 3000;
        uint256 proceedsShare = 0.1e18;
        address buybackDst = address(0xBEEF);

        bytes memory initData = _defaultPoolInitializerData();
        bytes memory rehypeData = abi.encode(
            RehypeInitData({
                numeraire: address(0),
                buybackDst: buybackDst,
                customFee: customFee,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.2e18,
                    assetFeesToNumeraireBuybackWad: 0.2e18,
                    assetFeesToBeneficiaryWad: 0.3e18,
                    assetFeesToLpWad: 0.3e18,
                    numeraireFeesToAssetBuybackWad: 0.2e18,
                    numeraireFeesToNumeraireBuybackWad: 0.2e18,
                    numeraireFeesToBeneficiaryWad: 0.3e18,
                    numeraireFeesToLpWad: 0.3e18
                })
            })
        );
        bytes memory migratorData =
            _splitMigratorData(false, address(rehypeHookMigrator), rehypeData, PROCEEDS_RECIPIENT, proceedsShare);
        bytes memory tokenFactoryData = _defaultTokenFactoryData();

        (address asset,, address timelock,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: initData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: bytes32(uint256(11))
            })
        );

        (address storedRecipient,, uint256 storedShare) = migrator.splitConfigurationOf(address(0), asset);
        assertEq(storedRecipient, PROCEEDS_RECIPIENT);
        assertEq(storedShare, proceedsShare);

        uint256 recipientBalanceBefore = PROCEEDS_RECIPIENT.balance;

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,, MigratorStatus migratorStatus) = migrator.getAssetData(address(0), asset);
        assertEq(uint8(migratorStatus), uint8(MigratorStatus.Locked), "Pool should be Locked after migrate");

        (address storedAsset, address storedNumeraire, address storedBuybackDst) =
            rehypeHookMigrator.getPoolInfo(poolKey.toId());
        assertEq(storedAsset, asset, "Rehype hook should store the migrated asset");
        assertEq(storedNumeraire, address(0), "Rehype hook should store the migrated numeraire");
        assertEq(storedBuybackDst, buybackDst, "Rehype hook should store the configured buyback destination");

        (
            uint256 assetFeesToAssetBuybackWad,
            uint256 assetFeesToNumeraireBuybackWad,
            uint256 assetFeesToBeneficiaryWad,
            uint256 assetFeesToLpWad,
            uint256 numeraireFeesToAssetBuybackWad,
            uint256 numeraireFeesToNumeraireBuybackWad,
            uint256 numeraireFeesToBeneficiaryWad,
            uint256 numeraireFeesToLpWad
        ) = rehypeHookMigrator.getFeeDistributionInfo(poolKey.toId());

        assertEq(assetFeesToAssetBuybackWad, 0.2e18);
        assertEq(assetFeesToNumeraireBuybackWad, 0.2e18);
        assertEq(assetFeesToBeneficiaryWad, 0.3e18);
        assertEq(assetFeesToLpWad, 0.3e18);
        assertEq(numeraireFeesToAssetBuybackWad, 0.2e18);
        assertEq(numeraireFeesToNumeraireBuybackWad, 0.2e18);
        assertEq(numeraireFeesToBeneficiaryWad, 0.3e18);
        assertEq(numeraireFeesToLpWad, 0.3e18);
        assertEq(uint8(rehypeHookMigrator.getFeeRoutingMode(poolKey.toId())), uint8(FeeRoutingMode.DirectBuyback));

        (,,,,,, uint24 storedCustomFee) = rehypeHookMigrator.getHookFees(poolKey.toId());
        assertEq(storedCustomFee, customFee, "Rehype hook should store the configured custom fee");

        assertGt(
            PROCEEDS_RECIPIENT.balance - recipientBalanceBefore,
            0,
            "Proceeds recipient should receive a split during migration"
        );

        (PoolKey memory streamKey, address streamRecipient, uint32 startDate, uint32 lockDuration, bool isUnlocked) =
            locker.streams(poolKey.toId());
        assertEq(address(streamKey.hooks), address(migrator));
        assertEq(streamRecipient, timelock);
        assertEq(lockDuration, 30 days);
        assertEq(isUnlocked, false);
        assertGt(startDate, 0);

        _swapOnMigrationPool(asset);

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeHookMigrator.getHookFees(poolKey.toId());
        assertTrue(
            beneficiaryFees0 + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1 > 0,
            "Rehype hook should still accrue post-migration fees when a split is configured"
        );
    }

    function _defaultTokenFactoryData() internal pure returns (bytes memory) {
        return dopplerERC20V1FactoryData(
            "Doppler Hook Migrator Test Token", "DHMT", "TOKEN_URI", 0, 0, address(0), new address[](0)
        );
    }

    function _defaultPoolInitializerData() internal pure returns (bytes memory) {
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

    function _defaultRehypeData() internal pure returns (bytes memory) {
        return abi.encode(
            RehypeInitData({
                numeraire: address(0),
                buybackDst: address(0xBEEF),
                customFee: 3000,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.2e18,
                    assetFeesToNumeraireBuybackWad: 0.2e18,
                    assetFeesToBeneficiaryWad: 0.3e18,
                    assetFeesToLpWad: 0.3e18,
                    numeraireFeesToAssetBuybackWad: 0.2e18,
                    numeraireFeesToNumeraireBuybackWad: 0.2e18,
                    numeraireFeesToBeneficiaryWad: 0.3e18,
                    numeraireFeesToLpWad: 0.3e18
                })
            })
        );
    }

    function _defaultMigratorData(
        bool useDynamicFee,
        address hook,
        bytes memory onInitializationCalldata
    ) internal pure returns (bytes memory) {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        return abi.encode(
            uint24(3000),
            useDynamicFee,
            int24(8),
            uint32(30 days),
            beneficiaries,
            hook,
            onInitializationCalldata,
            new bytes(0),
            address(0),
            uint256(0)
        );
    }

    function _migratorDataWithBeneficiaries(
        bool useDynamicFee,
        address hook,
        bytes memory onInitializationCalldata,
        BeneficiaryData[] memory beneficiaries,
        uint32 lockDuration
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint24(3000),
            useDynamicFee,
            int24(8),
            lockDuration,
            beneficiaries,
            hook,
            onInitializationCalldata,
            new bytes(0),
            address(0),
            uint256(0)
        );
    }

    function _splitMigratorData(
        bool useDynamicFee,
        address hook,
        bytes memory onInitializationCalldata,
        address proceedsRecipient,
        uint256 proceedsShare
    ) internal pure returns (bytes memory) {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        return abi.encode(
            uint24(3000),
            useDynamicFee,
            int24(8),
            uint32(30 days),
            beneficiaries,
            hook,
            onInitializationCalldata,
            proceedsRecipient,
            proceedsShare
        );
    }

    function _poolInitializerDataWithFee(uint24 fee) internal pure returns (bytes memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: WAD });

        return abi.encode(
            InitData({
                fee: fee,
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

    function _poolInitializerDataWithTickSpacing(int24 tickSpacing) internal pure returns (bytes memory) {
        int24 tickLower = int24(int256(tickSpacing) * -100);
        int24 tickUpper = int24(int256(tickSpacing) * 100);

        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: tickLower, tickUpper: tickUpper, numPositions: 10, shares: WAD });

        return abi.encode(
            InitData({
                fee: 0,
                tickSpacing: tickSpacing,
                curves: curves,
                beneficiaries: new BeneficiaryData[](0),
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: new bytes(0),
                graduationDopplerHookCalldata: new bytes(0),
                farTick: tickLower
            })
        );
    }

    function _swapOnInitializerPool(address asset) internal {
        (,,,, PoolStatus status, PoolKey memory poolKey,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));

        uint256 swapAmount = 0.1 ether;
        deal(address(this), swapAmount);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _swapOnInitializerPoolWithERC20Numeraire(address asset, address numeraire) internal {
        (,,,, PoolStatus status, PoolKey memory poolKey,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));

        uint256 swapAmount = 0.1 ether;
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        address inputToken = isToken0 ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
        assertEq(inputToken, numeraire, "initializer input should be numeraire");

        deal(inputToken, address(this), swapAmount);
        ERC20(inputToken).approve(address(swapRouter), swapAmount);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _swapOnInitializerPoolBidirectional(address asset, bool reverse) internal {
        (,,,, PoolStatus status, PoolKey memory poolKey,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));

        uint256 swapAmount = 0.1 ether;
        deal(address(this), swapAmount);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory buyParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta buyDelta =
            swapRouter.swap{ value: swapAmount }(poolKey, buyParams, PoolSwapTest.TestSettings(false, false), "");

        if (reverse) {
            ERC20(asset).approve(address(swapRouter), type(uint256).max);
            int256 amountToSwapBack = isToken0
                ? -int256(uint256(uint128(buyDelta.amount0())) / 2)
                : -int256(uint256(uint128(buyDelta.amount1())) / 2);

            IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                zeroForOne: isToken0,
                amountSpecified: amountToSwapBack,
                sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            swapRouter.swap(poolKey, sellParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        }
    }

    function _swapOnMigrationPool(address asset) internal {
        _swapOnMigrationPoolFor(asset, address(this), 0.1 ether);
    }

    function _swapOnMigrationPoolFor(address asset, address payer, uint256 swapAmount) internal {
        PoolKey memory poolKey = _migrationPoolKey(asset);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        if (Currency.unwrap(poolKey.currency0) == address(0) || Currency.unwrap(poolKey.currency1) == address(0)) {
            deal(payer, swapAmount);
            vm.prank(payer);
            swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
            return;
        }

        address inputToken = isToken0 ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
        deal(inputToken, payer, swapAmount);
        vm.prank(payer);
        ERC20(inputToken).approve(address(swapRouter), swapAmount);
        vm.prank(payer);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _migrationPoolKey(address asset) internal view returns (PoolKey memory poolKey) {
        (address token0, address token1) = migrator.getPair(asset);
        MigratorStatus status;
        (, poolKey,,,,,, status) = migrator.getAssetData(token0, token1);
        assertEq(uint8(status), uint8(MigratorStatus.Locked), "migration pool should be locked");
    }

    function _assertNoFreeMigrationBalances(PoolKey memory poolKey) internal view {
        assertEq(poolKey.currency0.balanceOf(address(migrator)), 0, "migrator should not retain currency0");
        assertEq(poolKey.currency1.balanceOf(address(migrator)), 0, "migrator should not retain currency1");
        assertEq(poolKey.currency0.balanceOf(address(locker)), 0, "locker should not retain currency0 dust");
        assertEq(poolKey.currency1.balanceOf(address(locker)), 0, "locker should not retain currency1 dust");
    }

    function _pickFeeTier(uint256 feeSeed) internal pure returns (uint24) {
        uint256 index = feeSeed % 4;
        if (index == 0) return 0;
        if (index == 1) return 500;
        if (index == 2) return 3000;
        return 10_000;
    }
}
