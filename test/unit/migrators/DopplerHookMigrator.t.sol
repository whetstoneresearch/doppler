// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";

import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";
import { DopplerHookMigrator, PoolState, PoolStatus } from "src/migrators/DopplerHookMigrator.sol";
import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries
} from "src/types/BeneficiaryData.sol";

contract AirlockMock {
    address public owner;
    mapping(address asset => address timelock) public getTimelock;

    struct AssetData {
        address numeraire;
        address timelock;
        address governance;
        address liquidityMigrator;
        address poolInitializer;
        address pool;
        address migrationPool;
        uint256 numTokensToSell;
        uint256 totalSupply;
        address integrator;
    }

    constructor(address owner_) {
        owner = owner_;
    }

    function setTimelock(address asset, address timelock_) external {
        getTimelock[asset] = timelock_;
    }

    function getAssetData(address asset) external view returns (AssetData memory) {
        return AssetData({
            numeraire: address(0),
            timelock: getTimelock[asset],
            governance: address(0),
            liquidityMigrator: address(0),
            poolInitializer: address(0),
            pool: address(0),
            migrationPool: address(0),
            numTokensToSell: 0,
            totalSupply: 0,
            integrator: address(0)
        });
    }
}

contract MockDopplerHook is IDopplerHook {
    address public initializer;
    bool public onInitCalled;
    bool public onGradCalled;
    Currency public feeCurrency;
    int128 public hookDelta;

    constructor(address initializer_) {
        initializer = initializer_;
    }

    function setSwapReturn(Currency feeCurrency_, int128 hookDelta_) external {
        feeCurrency = feeCurrency_;
        hookDelta = hookDelta_;
    }

    function onInitialization(address, PoolKey calldata, bytes calldata) external override {
        onInitCalled = true;
    }

    function onSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view override returns (Currency, int128) {
        return (feeCurrency, hookDelta);
    }

    function onGraduation(address, PoolKey calldata, bytes calldata) external override {
        onGradCalled = true;
    }
}

contract DopplerHookMigratorTest is Deployers {
    using StateLibrary for IPoolManager;
    address public owner = makeAddr("Owner");
    address public recipient = makeAddr("Recipient");

    address constant BENEFICIARY_1 = address(0x1111);
    address constant BENEFICIARY_2 = address(0x2222);

    int24 constant TICK_SPACING = 8;
    uint24 constant FEE = 3000;
    uint32 constant LOCK_DURATION = 30 days;

    AirlockMock public airlock;
    DopplerHookMigrator public migrator;
    StreamableFeesLockerV2 public locker;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");

        airlock = new AirlockMock(owner);

        uint160 hookFlags =
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

        locker = new StreamableFeesLockerV2(manager, owner);
        address migratorAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorAddress));
        deployCodeTo("DopplerHookMigrator", abi.encode(address(airlock), manager, locker), migratorAddress);

        vm.prank(owner);
        locker.approveMigrator(address(migrator));
    }

    function test_constructor() public view {
        assertEq(address(migrator.airlock()), address(airlock));
        assertEq(address(migrator.poolManager()), address(manager));
        assertEq(address(migrator.locker()), address(locker));
    }

    function test_initialize_StoresPoolKey() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        (
            bool isToken0,
            PoolKey memory poolKey,
            uint32 lockDuration,
            bool useDynamicFee,
            uint24 feeOrInitialDynamicFee,
            ,
            ,
            
        ) = migrator.getAssetData(token0, token1);

        assertEq(Currency.unwrap(poolKey.currency0), token0);
        assertEq(Currency.unwrap(poolKey.currency1), token1);
        assertEq(poolKey.fee, FEE);
        assertEq(poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(poolKey.hooks), address(migrator));
        assertEq(lockDuration, LOCK_DURATION);
        assertEq(isToken0, asset == token0);
        assertFalse(useDynamicFee);
        assertEq(feeOrInitialDynamicFee, FEE);
    }

    function test_initialize() public {
        (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            bytes memory onGraduationCalldata
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(
            feeOrInitialDynamicFee,
            tickSpacing,
            lockDuration,
            beneficiaries,
            useDynamicFee,
            dopplerHook,
            onInitializationCalldata,
            onGraduationCalldata
        );
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.prank(address(airlock));
        migrator.initialize(asset, numeraire, data);
    }

    function test_initialize_RevertsIfSenderNotAirlock() public {
        (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            bytes memory onGraduationCalldata
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(
            feeOrInitialDynamicFee,
            tickSpacing,
            lockDuration,
            beneficiaries,
            useDynamicFee,
            dopplerHook,
            onInitializationCalldata,
            onGraduationCalldata
        );
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.expectRevert(SenderNotAirlock.selector);
        migrator.initialize(asset, numeraire, data);
    }

    function test_migrate_RevertIfNotInitialized() public {
        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSignature("PoolNotInitialized()"));
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), recipient);
    }

    function test_initialize_RevertZeroAddressBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(UnorderedBeneficiaries.selector));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertZeroShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: owner, shares: 0 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertIncorrectTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.35e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidTotalShares.selector));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_IncludesDopplerOwnerBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.4e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: owner, shares: 0.1e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.951e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.049e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, 0.049e18));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertProtocolOwnerNotFound() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.4e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.6e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerBeneficiary.selector));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertDynamicFeeTooHigh() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSignature("LPFeeTooHigh(uint24,uint256)", 150_000, 150_001));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(150_001, TICK_SPACING, LOCK_DURATION, beneficiaries, true, address(0), new bytes(0), new bytes(0))
        );
    }

    function test_initialize_RevertHookRequiresDynamicFee() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address hookAddr = makeAddr("Hook");
        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(1 << 3)); // REQUIRES_DYNAMIC_LP_FEE_FLAG

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSignature("HookRequiresDynamicLPFee()"));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, hookAddr, new bytes(0), new bytes(0))
        );
    }

    function test_migrate_RevertIfHookDisabledAfterInitialize() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;
        address hookAddr = makeAddr("Hook");

        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(ON_SWAP_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, hookAddr, new bytes(0), new bytes(0))
        );

        // Disable hook after initialize
        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(0));

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSignature("DopplerHookNotEnabled()"));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);
    }

    function test_setDopplerHookState_StoresFlags() public {
        address hook1 = makeAddr("Hook1");
        address hook2 = makeAddr("Hook2");
        address[] memory hooks = new address[](2);
        hooks[0] = hook1;
        hooks[1] = hook2;
        uint256[] memory flags = new uint256[](2);
        flags[0] = ON_SWAP_FLAG;
        flags[1] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;

        vm.prank(owner);
        migrator.setDopplerHookState(hooks, flags);

        assertEq(migrator.isDopplerHookEnabled(hook1), flags[0]);
        assertEq(migrator.isDopplerHookEnabled(hook2), flags[1]);
    }

    function test_setDopplerHookState_RevertLengthMismatch() public {
        address[] memory hooks = new address[](1);
        uint256[] memory flags = new uint256[](2);
        hooks[0] = makeAddr("Hook1");
        flags[0] = ON_SWAP_FLAG;
        flags[1] = ON_INITIALIZATION_FLAG;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthsMismatch()"));
        migrator.setDopplerHookState(hooks, flags);
    }

    function test_setDopplerHookState_RevertIfNotOwner() public {
        address[] memory hooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        hooks[0] = makeAddr("Hook1");
        flags[0] = ON_SWAP_FLAG;

        vm.expectRevert(abi.encodeWithSignature("SenderNotAirlockOwner()"));
        migrator.setDopplerHookState(hooks, flags);
    }

    function test_setDopplerHook_RevertUnauthorized() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(asset < numeraire ? asset : numeraire).transfer(address(migrator), 1e6);
        Currency.wrap(asset < numeraire ? numeraire : asset).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, asset < numeraire ? asset : numeraire, asset < numeraire ? numeraire : asset, recipient);

        airlock.setTimelock(asset, owner);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAuthorized()"));
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0), new bytes(0));
    }

    function test_setDopplerHook_RevertNotEnabled() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        airlock.setTimelock(asset, owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("DopplerHookNotEnabled()"));
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0), new bytes(0));
    }

    function test_setDopplerHook_RevertRequiresDynamicFee() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        address hookAddr = makeAddr("Hook");
        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(1 << 3)); // REQUIRES_DYNAMIC_LP_FEE_FLAG

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        airlock.setTimelock(asset, owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("HookRequiresDynamicLPFee()"));
        migrator.setDopplerHook(asset, hookAddr, new bytes(0), new bytes(0));
    }

    function test_setDopplerHook_CallsOnInitialization() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        MockDopplerHook mockHook = new MockDopplerHook(address(migrator));
        assertTrue(address(mockHook) != address(this));

        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(address(mockHook)), _singleFlag(ON_INITIALIZATION_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        airlock.setTimelock(asset, owner);
        vm.prank(owner);
        migrator.setDopplerHook(asset, address(mockHook), new bytes(0), new bytes(0));

        assertTrue(mockHook.onInitCalled());
    }

    function test_updateDynamicLPFee_RevertUnauthorized() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        MockDopplerHook mockHook = new MockDopplerHook(address(migrator));
        assertTrue(address(mockHook) != address(this));

        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(address(mockHook)), _singleFlag(ON_SWAP_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(10_000, TICK_SPACING, LOCK_DURATION, beneficiaries, true, address(mockHook), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        PoolState memory state = migrator.getMigratorState(asset);
        address stateNumeraire = state.numeraire;
        PoolKey memory key = state.poolKey;
        address storedHook = state.dopplerHook;
        bytes memory gradData = state.onGraduationCalldata;
        PoolStatus status = state.status;
        stateNumeraire;
        gradData;
        status;
        assertEq(storedHook, address(mockHook));
        assertEq(address(key.hooks), address(migrator));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        (,,, bool useDynamicFee,, , ,) = migrator.getAssetData(token0, token1);
        assertTrue(useDynamicFee);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAuthorized()"));
        migrator.updateDynamicLPFee(asset, 1000);
    }

    function test_updateDynamicLPFee_SucceedsForHook() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        MockDopplerHook mockHook = new MockDopplerHook(address(migrator));

        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(address(mockHook)), _singleFlag(ON_SWAP_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(10_000, TICK_SPACING, LOCK_DURATION, beneficiaries, true, address(mockHook), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        PoolState memory state = migrator.getMigratorState(asset);
        address stateNumeraire = state.numeraire;
        PoolKey memory key = state.poolKey;
        address storedHook = state.dopplerHook;
        bytes memory gradData = state.onGraduationCalldata;
        PoolStatus status = state.status;
        stateNumeraire;
        gradData;
        status;
        assertEq(storedHook, address(mockHook));
        assertEq(address(key.hooks), address(migrator));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        (,,, bool useDynamicFee,, , ,) = migrator.getAssetData(token0, token1);
        assertTrue(useDynamicFee);
        vm.prank(address(mockHook));
        migrator.updateDynamicLPFee(asset, 1_000);
    }

    function test_migrate_SetsInitialDynamicFee() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(10_000, TICK_SPACING, LOCK_DURATION, beneficiaries, true, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
        (, , uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 10_000);
    }

    /// forge-config: default.fuzz.runs = 256
    function test_initialize_FuzzDynamicFeeWithinCap(uint24 fee) public {
        vm.assume(fee <= 150_000);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(fee, TICK_SPACING, LOCK_DURATION, beneficiaries, true, address(0), new bytes(0), new bytes(0))
        );
    }

    function _singleAddr(address value) private pure returns (address[] memory addrs) {
        addrs = new address[](1);
        addrs[0] = value;
    }

    function _singleFlag(uint256 value) private pure returns (uint256[] memory flags) {
        flags = new uint256[](1);
        flags[0] = value;
    }

    /// forge-config: default.fuzz.runs = 256
    function test_migrate(bool isUsingETH, bool hasRecipient, uint64 balance0, uint64 balance1) public {
        vm.assume(balance0 > 1e6 && balance1 > 1e6);
        if (balance0 >= 1e12 || balance1 >= 1e12) return;
        vm.assume(balance0 < 1e12 && balance1 < 1e12);
        vm.assume(balance0 < 1e12 && balance1 < 1e12);
        (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            bytes memory onGraduationCalldata
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(
            feeOrInitialDynamicFee,
            tickSpacing,
            lockDuration,
            beneficiaries,
            useDynamicFee,
            dopplerHook,
            onInitializationCalldata,
            onGraduationCalldata
        );
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        if (isUsingETH) {
            asset = numeraire;
            token1 = asset;
            token0 = address(0);
            numeraire = address(0);
        }

        vm.prank(address(airlock));
        migrator.initialize(asset, numeraire, data);

        if (isUsingETH) {
            deal(address(migrator), balance0);
        } else {
            Currency.wrap(token0).transfer(address(migrator), balance0);
        }
        Currency.wrap(token1).transfer(address(migrator), balance1);

        vm.prank(address(airlock));
        migrator.migrate(
            Constants.SQRT_PRICE_1_1,
            token0,
            token1,
            hasRecipient ? recipient : address(0xdead)
        );

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
        (,, uint32 startDate,,) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);

        if (isUsingETH) {
            assertEq(address(migrator).balance, 0);
        } else {
            assertEq(Currency.wrap(token0).balanceOf(address(migrator)), 0);
        }
        assertEq(Currency.wrap(token1).balanceOf(address(migrator)), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function test_migrate_FuzzTickTwoSidedDoesNotRevert(int24 tick, uint32 balance0, uint32 balance1) public {
        vm.assume(balance0 > 1e6 && balance1 > 1e6);
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
        vm.assume(tick >= minTick && tick <= maxTick);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, false, address(0), new bytes(0), new bytes(0))
        );

        Currency.wrap(token0).transfer(address(migrator), balance0);
        Currency.wrap(token1).transfer(address(migrator), balance1);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            balance0,
            balance1
        );
        vm.assume(liq > 0);
        vm.assume(liq <= uint128(type(int128).max));

        vm.prank(address(airlock));
        migrator.migrate(sqrtPriceX96, token0, token1, recipient);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
        (,, uint32 startDate,,) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);
    }

    // TODO: test migrate initializes pool, sets dynamic fee and enforces hook allowlist/flags
    // TODO: test setDopplerHook authorization and upgrade ban toggling
    // TODO: test graduate and onGraduation callback routing
    // TODO: test afterSwap delta settlement and disabled hook behavior
    // TODO: test updateDynamicLPFee access control and cap

    function _prepareInitializeData()
        internal
        returns (
            uint24 feeOrInitialDynamicFee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            bytes memory onGraduationCalldata
        )
    {
        feeOrInitialDynamicFee = 3000;
        tickSpacing = 1;
        lockDuration = 7 days;
        useDynamicFee = false;
        dopplerHook = address(0);
        onInitializationCalldata = new bytes(0);
        onGraduationCalldata = new bytes(0);

        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

    }
}
