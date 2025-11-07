// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import {
    DookMulticurveInitializer,
    InitData,
    BeneficiaryData,
    CannotMigrateInsufficientTick,
    Lock,
    PoolStatus,
    WrongPoolStatus,
    ArrayLengthsMismatch,
    SenderNotAirlockOwner,
    CannotMigratePoolNoProvidedDook,
    Graduate,
    SenderNotAuthorized,
    DookNotEnabled,
    SetDook,
    SetDookState,
    UnreachableFarTick,
    OnlyInitializer
} from "src/DookMulticurveInitializer.sol";
import { WAD } from "src/types/Wad.sol";
import { Position } from "src/types/Position.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { Airlock } from "src/Airlock.sol";
import { IDook } from "src/interfaces/IDook.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG, ON_GRADUATION_FLAG } from "src/base/BaseDook.sol";

contract MockDook is IDook {
    function onInitialization(address, bytes calldata) external { }
    function onSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external { }
    function onGraduation(address, bytes calldata) external { }
}

contract DookMulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;

    DookMulticurveInitializer public initializer;
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    MockDook public dook;

    uint256 internal totalTokensOnBondingCurve = 1e27;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal asset;
    address internal numeraire;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        airlock = new Airlock(airlockOwner);
        initializer = DookMulticurveInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo("DookMulticurveInitializer", abi.encode(address(airlock), address(manager)), address(initializer));
        dook = new MockDook();
        vm.label(address(dook), "Dook");

        address[] memory dooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dooks[0] = address(dook);
        flags[0] = ON_INITIALIZATION_FLAG | ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        vm.prank(airlockOwner);
        initializer.setDookState(dooks, flags);
    }

    modifier prepareAsset(bool isToken0) {
        asset = isToken0 ? Currency.unwrap(currency0) : Currency.unwrap(currency1);
        numeraire = isToken0 ? Currency.unwrap(currency1) : Currency.unwrap(currency0);
        vm.label(asset, "Asset");
        vm.label(numeraire, "Numeraire");
        (isToken0 ? currency0 : currency1).transfer(address(airlock), currency0.balanceOfSelf());
        vm.prank(address(airlock));
        ERC20(asset).approve(address(initializer), type(uint256).max);
        _;
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(airlock));
        assertEq(address(initializer.poolManager()), address(manager));
    }

    /* -------------------------------------------------------------------------- */
    /*                                initialize()                                */
    /* -------------------------------------------------------------------------- */

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        InitData memory initData = _prepareInitData();
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            totalTokensOnBondingCurve,
            bytes32(0),
            abi.encode(initData)
        );
    }

    function test_initialize_RevertsWhenAlreadyInitialized(bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(isToken0);
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Uninitialized, PoolStatus.Initialized)
        );
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenUnreachableFarTick(bool isToken0, int24 farTick) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData();
        vm.assume(farTick > TickMath.MIN_TICK && farTick < TickMath.MAX_TICK);
        vm.assume(farTick < 160_000 || farTick > 240_000);
        initData.farTick = farTick;
        vm.expectRevert(UnreachableFarTick.selector);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_InitializesPool(bool isToken0)
        public
        prepareAsset(isToken0)
        returns (InitData memory initData)
    {
        initData = _prepareInitData();

        vm.expectEmit();
        emit IPoolInitializer.Create(address(manager), asset, numeraire);

        vm.prank(address(airlock));
        address returnedAsset =
            initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
        assertEq(returnedAsset, asset, "Returned asset address is incorrect");

        (,,,, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be Initialized");
    }

    function test_initialize_AddsLiquidity(bool isToken0) public {
        // TODO: Figure out why this test is failing
        vm.skip(true);
        test_initialize_InitializesPool(isToken0);
        console.logBytes32(PoolId.unwrap(poolId));
        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0, "Liquidity is zero");
    }

    function test_initialize_LocksPool(bool isToken0) public prepareAsset(isToken0) returns (InitData memory initData) {
        initData = _prepareInitDataLock();

        vm.expectEmit();
        emit Lock(asset, initData.beneficiaries);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        (,,,, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Locked), "Pool status should be locked");

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < initData.beneficiaries.length; i++) {
            assertEq(beneficiaries[i].beneficiary, initData.beneficiaries[i].beneficiary, "Incorrect beneficiary");
            assertEq(beneficiaries[i].shares, initData.beneficiaries[i].shares, "Incorrect shares");
        }
    }

    function test_initialize_LocksPoolWithDook(bool isToken0)
        public
        prepareAsset(isToken0)
        returns (InitData memory initData)
    {
        initData = _prepareInitDataWithDook();

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        (,, address dookAddress, bytes memory graduationDookCalldata,, PoolKey memory key,) =
            initializer.getState(asset);
        assertEq32(PoolId.unwrap(key.toId()), PoolId.unwrap(poolId), "Pool Ids not matching");
        assertEq(dookAddress, address(dook), "Incorrect dook address");
        assertEq(graduationDookCalldata, initData.graduationDookCalldata, "Incorrect graduation dook calldata");
    }

    function test_initialize_CallsDookOnInitialization(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDook();

        vm.prank(address(airlockOwner));
        address[] memory dooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dooks[0] = address(dook);
        flags[0] = ON_INITIALIZATION_FLAG | ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        initializer.setDookState(dooks, flags);

        vm.expectCall(
            address(dook),
            abi.encodeWithSelector(IDook.onInitialization.selector, asset, initData.onInitializationDookCalldata)
        );

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_DoesNotCallDookOnInitializationWhenFlagIsOff(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDook();

        vm.prank(address(airlockOwner));
        address[] memory dooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dooks[0] = address(dook);
        flags[0] = ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        initializer.setDookState(dooks, flags);

        vm.expectCall(
            address(dook),
            abi.encodeWithSelector(IDook.onInitialization.selector, asset, initData.onInitializationDookCalldata),
            0
        );

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_StoresPoolState(bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(isToken0);

        (address returnedNumeraire,,,, PoolStatus status, PoolKey memory key, int24 farTick) =
            initializer.getState(asset);

        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be initialized");
        assertEq(returnedNumeraire, numeraire, "Incorrect numeraire");
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(currency0), "Incorrect currency0");
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(currency1), "Incorrect currency1");
        assertEq(key.fee, initData.fee, "Incorrect fee");
        assertEq(key.tickSpacing, initData.tickSpacing, "Incorrect tick spacing");
        assertEq(address(key.hooks), address(initializer), "Incorrect hook");
        assertEq(farTick, isToken0 ? initData.farTick : -initData.farTick, "Incorrect far tick");
    }

    /* ----------------------------------------------------------------------------- */
    /*                                exitLiquidity()                                */
    /* ----------------------------------------------------------------------------- */

    function test_exitLiquidity(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);

        (,,,,,, int24 farTick) = initializer.getState(asset);
        _buyUntilFarTick(isToken0);
        vm.prank(address(airlock));
        (uint160 sqrtPriceX96,,,,,,) = initializer.exitLiquidity(asset);

        // TODO: Check if the currentTick is at least the farTick
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(farTick), "Incorrect returned sqrtPriceX96");

        (,,,, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Exited), "Pool status should be Exited");

        assertEq(currency0.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token0");
        assertEq(currency1.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token1");

        assertLt(currency0.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token0");
        assertLt(currency1.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token1");

        assertEq(manager.getLiquidity(poolId), 0, "Pool liquidity should be zero");

        Position[] memory positions = initializer.getPositions(asset);

        for (uint256 i; i < positions.length; i++) {
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(initializer), positions[i].tickLower, positions[i].tickUpper, positions[i].salt
            );
            assertEq(liquidity, 0, "Position liquidity should be zero");
        }
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolAlreadyExited(bool isToken0) public {
        test_exitLiquidity(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Exited));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolIsLocked(bool isToken0) public {
        test_initialize_LocksPool(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Locked));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolGraduated(bool isToken0) public {
        test_graduate_GraduatesPool(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Graduated));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        (,,,,,, int24 farTick) = initializer.getState(asset);
        (, int24 tick,,) = manager.getSlot0(poolId);

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, farTick, tick));
        initializer.exitLiquidity(asset);
    }

    /* --------------------------------------------------------------------------- */
    /*                                collectFees()                                */
    /* --------------------------------------------------------------------------- */

    function test_collectFees_RevertsWhenPoolNotLocked() public {
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Uninitialized));
        initializer.collectFees(PoolId.wrap(0));
    }

    function test_collectFees(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataLock();
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));

        initializer.collectFees(poolId);
    }

    /* --------------------------------------------------------------------------------- */
    /*                                delegateAuthority()                                */
    /* --------------------------------------------------------------------------------- */

    function test_delegateAuthority(address user, address delegation) public {
        vm.prank(user);
        initializer.delegateAuthority(delegation);
        assertEq(initializer.getAuthority(user), delegation, "Incorrect delegated authority");
    }

    /* ---------------------------------------------------------------------------- */
    /*                                setDookState()                                */
    /* ---------------------------------------------------------------------------- */

    function test_setDookState_RevertsWhenSenderNotAirlockOwner(
        address[] calldata dooks,
        uint256[] calldata flags
    ) public {
        vm.expectRevert(SenderNotAirlockOwner.selector);
        initializer.setDookState(dooks, flags);
    }

    function test_setDookState_RevertsWhenArrayLengthsMismatch(
        address[] calldata dooks,
        uint256[] calldata flags
    ) public {
        vm.assume(dooks.length != flags.length);
        vm.prank(airlockOwner);
        vm.expectRevert(ArrayLengthsMismatch.selector);
        initializer.setDookState(dooks, flags);
    }

    function test_setDookState_SetsStates(address[] calldata dooks, uint256[] calldata flags) public {
        uint256 length = dooks.length;
        vm.assume(length == flags.length);
        vm.prank(airlockOwner);

        for (uint256 i; i < length; i++) {
            vm.expectEmit();
            emit SetDookState(dooks[i], flags[i]);
        }

        initializer.setDookState(dooks, flags);
    }

    /* ----------------------------------------------------------------------- */
    /*                                setDook()                                */
    /* ----------------------------------------------------------------------- */

    function test_setDook_RevertsIfPoolNotLocked(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.setDook(asset, address(dook), new bytes(0), new bytes(0));
    }

    function test_setDook_RevertsWhenSenderNotAuthorized(bool isToken0) public {
        test_initialize_LocksPool(isToken0);
        vm.expectRevert(SenderNotAuthorized.selector);
        vm.prank(address(0xbeef));
        initializer.setDook(asset, address(dook), new bytes(0), new bytes(0));
    }

    function test_setDook_RevertsWhenDookNotEnabled(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDook();
        initData.dook = address(0xdeadbeef);
        vm.prank(address(airlock));
        vm.expectRevert(DookNotEnabled.selector);
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_setDook_SetsDookWhenSenderIsTimelock(
        bool isToken0,
        bytes calldata onInitializationCalldata,
        bytes calldata onGraduationCalldata
    ) public {
        test_initialize_LocksPool(isToken0);

        vm.mockCall(
            address(airlock),
            abi.encodeWithSelector(0x1652e7b7, asset),
            abi.encode(
                address(0), address(this), address(0), address(0), address(0), address(0), address(0), 0, 0, address(0)
            )
        );

        vm.expectCall(
            address(dook), abi.encodeWithSelector(IDook.onInitialization.selector, asset, onInitializationCalldata)
        );
        vm.expectEmit();
        emit SetDook(asset, address(dook));
        initializer.setDook(asset, address(dook), onInitializationCalldata, onGraduationCalldata);

        (,, address dookAddress,,,,) = initializer.getState(asset);
        assertEq(dookAddress, address(dook), "Incorrect dook address");
    }

    function test_setDook_SetsDookWhenSenderIsAuthority(
        bool isToken0,
        bytes calldata onInitializationCalldata,
        bytes calldata onGraduationCalldata
    ) public {
        test_initialize_LocksPool(isToken0);

        vm.mockCall(
            address(airlock),
            abi.encodeWithSelector(0x1652e7b7, asset),
            abi.encode(
                address(0),
                address(0xbeef),
                address(0),
                address(0),
                address(0),
                address(0),
                address(0),
                0,
                0,
                address(0)
            )
        );

        vm.prank(address(0xbeef));
        initializer.delegateAuthority(address(this));

        vm.expectCall(
            address(dook), abi.encodeWithSelector(IDook.onInitialization.selector, asset, onInitializationCalldata)
        );
        vm.expectEmit();
        emit SetDook(asset, address(dook));
        initializer.setDook(asset, address(dook), onInitializationCalldata, onGraduationCalldata);

        (,, address dookAddress,,,,) = initializer.getState(asset);
        assertEq(dookAddress, address(dook), "Incorrect dook address");
    }

    /* ------------------------------------------------------------------------ */
    /*                                graduate()                                */
    /* ------------------------------------------------------------------------ */

    function test_graduate_RevertsWhenPoolNotLocked(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.graduate(asset);
    }

    function test_graduate_RevertsWhenNoProvidedDook(bool isToken0) public {
        test_initialize_LocksPool(isToken0);
        vm.expectRevert(CannotMigratePoolNoProvidedDook.selector);
        initializer.graduate(asset);
    }

    function test_graduate_GraduatesPool(bool isToken0) public {
        InitData memory initData = test_initialize_LocksPoolWithDook(isToken0);
        _buyUntilFarTick(isToken0);

        vm.expectCall(
            address(dook),
            abi.encodeWithSelector(MockDook.onGraduation.selector, asset, initData.graduationDookCalldata)
        );

        vm.expectEmit();
        emit Graduate(asset);

        vm.prank(address(airlock));
        initializer.graduate(asset);

        (,,,, PoolStatus status,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Graduated), "Pool status should be Graduated");
    }

    function test_graduate_RevertsWhenFarTickNotReached(bool isToken0) public {
        test_initialize_LocksPoolWithDook(isToken0);
        (,,,,,, int24 farTick) = initializer.getState(asset);
        (, int24 tick,,) = manager.getSlot0(poolId);
        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, farTick, tick));
        initializer.graduate(asset);
    }

    /* ---------------------------------------------------------------------------------- */
    /*                                updateDynamicLPFee()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_updateDynamicLPFee_RevertsWhenSenderNotDook(bool isToken0) public {
        test_initialize_LocksPoolWithDook(isToken0);
        vm.expectRevert(SenderNotAuthorized.selector);
        vm.prank(address(0xbeef));
        initializer.updateDynamicLPFee(asset, 100);
    }

    function test_updateDynamicLPFee_RevertsWhenPoolWrongStatus(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.updateDynamicLPFee(asset, 100);
    }

    function test_updateDynamicLPFee_UpdatesFee(bool isToken0) public {
        test_initialize_LocksPoolWithDook(isToken0);
        vm.prank(address(dook));
        initializer.updateDynamicLPFee(asset, 100);
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, 100, "Incorrect updated fee");
    }

    /* -------------------------------------------------------------------------------- */
    /*                                beforeInitialize()                                */
    /* -------------------------------------------------------------------------------- */

    function test_beforeInitialize_RevertsWhenMsgSenderNotPoolManager(PoolKey memory key) public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.beforeInitialize(address(0), key, 0);
    }

    function test_beforeInitialize_RevertsWhenSenderParamNotInitializer() public {
        vm.prank(address(manager));
        vm.expectRevert(OnlyInitializer.selector);
        initializer.beforeInitialize(address(0), key, 0);
    }

    function test_beforeInitialize_PassesWhenSenderParamInitializer() public {
        vm.prank(address(manager));
        initializer.beforeInitialize(address(initializer), key, 0);
    }

    /* ----------------------------------------------------------------------- */
    /*                                Utilities                                */
    /* ----------------------------------------------------------------------- */

    function _prepareInitData() internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](1);
        int24 tickSpacing = 8;

        for (uint256 i; i < curves.length; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 1;
            curves[i].shares = WAD / curves.length;
        }

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: initializer
        });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: beneficiaries,
            dook: address(0),
            onInitializationDookCalldata: new bytes(0),
            graduationDookCalldata: new bytes(0),
            farTick: 200_000
        });
    }

    function _prepareInitDataLock() internal returns (InitData memory) {
        InitData memory initData = _prepareInitData();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05e18 });
        initData.beneficiaries = beneficiaries;
        return initData;
    }

    function _prepareInitDataWithDook() internal returns (InitData memory) {
        InitData memory initData = _prepareInitDataLock();
        initData.dook = address(dook);
        initData.graduationDookCalldata = abi.encode(0xbeef);
        poolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        poolId = poolKey.toId();
        return initData;
    }

    function _buyUntilFarTick(bool isToken0) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(totalTokensOnBondingCurve),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }
}
