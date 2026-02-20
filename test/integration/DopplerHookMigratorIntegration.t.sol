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

import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { ON_AFTER_SWAP_FLAG, ON_INITIALIZATION_FLAG } from "src/base/BaseDopplerHookMigrator.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { SaleHasNotStartedYet, ScheduledLaunchDopplerHook } from "src/dopplerHooks/ScheduledLaunchDopplerHook.sol";
import { InsufficientAmountLeft, SwapRestrictorDopplerHook } from "src/dopplerHooks/SwapRestrictorDopplerHook.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import {
    AssetData,
    DopplerHookMigrator,
    DopplerHookNotEnabled,
    PoolStatus as MigratorStatus
} from "src/migrators/DopplerHookMigrator.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract DopplerHookMigratorIntegrationTest is Deployers {
    using StateLibrary for IPoolManager;
    address internal constant AIRLOCK_OWNER = address(0xA111);
    address internal constant BENEFICIARY_1 = address(0x1111);
    address internal constant PROCEEDS_RECIPIENT = address(0x5555);

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    CloneERC20Factory public tokenFactory;
    NoOpGovernanceFactory public governanceFactory;
    StreamableFeesLockerV2 public locker;
    DopplerHookMigrator public migrator;
    TopUpDistributor public topUpDistributor;
    RehypeDopplerHook public rehypeHook;
    RehypeDopplerHookMigrator public rehypeHookMigrator;
    ScheduledLaunchDopplerHook public scheduledLaunchHook;
    SwapRestrictorDopplerHook public swapRestrictorHook;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(AIRLOCK_OWNER);
        tokenFactory = new CloneERC20Factory(address(airlock));
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

        locker = new StreamableFeesLockerV2(IPoolManager(address(manager)), AIRLOCK_OWNER);
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

        rehypeHook = new RehypeDopplerHook(address(migrator), manager);
        rehypeHookMigrator = new RehypeDopplerHookMigrator(migrator, manager);
        scheduledLaunchHook = new ScheduledLaunchDopplerHook(address(migrator));
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

    function test_fullFlow_CreateAndMigrate_WithHookInitialization() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(scheduledLaunchHook);
        flags[0] = ON_INITIALIZATION_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        uint256 startTime = block.timestamp + 1 days;
        bytes memory hookData = abi.encode(startTime);
        bytes memory migratorData = _defaultMigratorData(false, address(scheduledLaunchHook), hookData);
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
                salt: bytes32(uint256(2))
            })
        );

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        assertEq(scheduledLaunchHook.getStartingTimeOf(poolKey.toId()), 0, "Hook not initialized before migrate");

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        assertEq(
            scheduledLaunchHook.getStartingTimeOf(poolKey.toId()), startTime, "Hook should be initialized after migrate"
        );
    }

    function test_fullFlow_CreateAndMigrate_WithRehypeHook() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(rehypeHookMigrator);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        bytes memory rehypeData = abi.encode(address(0), address(0xBEEF), uint24(3000), 0.2e18, 0.2e18, 0.3e18, 0.3e18);
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

    function test_fullFlow_CreateAndMigrate_WithScheduledLaunchHook() public {
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(scheduledLaunchHook);
        flags[0] = ON_INITIALIZATION_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        uint256 startTime = block.timestamp + 1 days;
        bytes memory hookData = abi.encode(startTime);
        bytes memory migratorData = _defaultMigratorData(false, address(scheduledLaunchHook), hookData);
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
                salt: bytes32(uint256(11))
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        assertEq(scheduledLaunchHook.getStartingTimeOf(poolKey.toId()), startTime);

        vm.expectRevert(abi.encodeWithSelector(SaleHasNotStartedYet.selector, startTime, block.timestamp));
        vm.prank(address(migrator));
        scheduledLaunchHook.onSwap(
            address(0), poolKey, IPoolManager.SwapParams(false, 0, 0), BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );

        vm.warp(block.timestamp + 2 days);
        _swapOnMigrationPool(asset);
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
        dopplerHooks[0] = address(scheduledLaunchHook);
        flags[0] = ON_INITIALIZATION_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);

        bytes memory initData = _defaultPoolInitializerData();
        uint256 startTime = block.timestamp + 1 days;
        bytes memory hookData = abi.encode(startTime);
        bytes memory migratorData = _defaultMigratorData(false, address(scheduledLaunchHook), hookData);
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

    function _defaultTokenFactoryData() internal pure returns (bytes memory) {
        return
            abi.encode(
                "Doppler Hook Migrator Test Token", "DHMT", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"
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
        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);

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

    function _pickFeeTier(uint256 feeSeed) internal pure returns (uint24) {
        uint256 index = feeSeed % 4;
        if (index == 0) return 0;
        if (index == 1) return 500;
        if (index == 2) return 3000;
        return 10_000;
    }
}
