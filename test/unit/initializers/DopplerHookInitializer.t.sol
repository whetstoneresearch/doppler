// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";

import { Airlock } from "src/Airlock.sol";
import { ON_GRADUATION_FLAG, ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    ArrayLengthsMismatch,
    BeneficiaryData,
    CannotMigrateInsufficientTick,
    CannotMigratePoolNoProvidedDopplerHook,
    DelegateAuthority,
    DopplerHookInitializer,
    DopplerHookNotEnabled,
    Graduate,
    InitData,
    LPFeeTooHigh,
    Lock,
    MAX_LP_FEE,
    ModifyLiquidity,
    OnlyInitializer,
    PoolStatus,
    SenderNotAirlockOwner,
    SenderNotAuthorized,
    SetDopplerHook,
    SetDopplerHookState,
    Swap,
    UnreachableFarTick,
    WrongPoolStatus
} from "src/initializers/DopplerHookInitializer.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve, Multicurve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Position } from "src/types/Position.sol";
import { WAD } from "src/types/Wad.sol";

contract MockDopplerHook is IDopplerHook {
    function onInitialization(address, PoolKey calldata, bytes calldata) external { }
    function onSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (Currency, int128) { }
    function onGraduation(address, PoolKey calldata, bytes calldata) external { }
}

contract DopplerHookMulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;

    DopplerHookInitializer public initializer;
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    MockDopplerHook public dopplerHook;

    uint256 internal totalTokensOnBondingCurve = 1e27;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal asset;
    address internal numeraire;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        airlock = new Airlock(airlockOwner);
        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo(
            "DopplerHookInitializer",
            abi.encode(address(airlock), address(manager), address(0), address(0)),
            address(initializer)
        );
        dopplerHook = new MockDopplerHook();
        vm.label(address(dopplerHook), "DopplerHook");

        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(dopplerHook);
        flags[0] = ON_INITIALIZATION_FLAG | ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        vm.prank(airlockOwner);
        initializer.setDopplerHookState(dopplerHooks, flags);
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

    function test_initialize_RevertsWhenSenderNotAirlock(InitDataParams memory params) public {
        InitData memory initData = _prepareInitData(params);
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            totalTokensOnBondingCurve,
            bytes32(0),
            abi.encode(initData)
        );
    }

    function test_initialize_RevertsWhenAlreadyInitialized(InitDataParams memory params, bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(params, isToken0);
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Uninitialized, PoolStatus.Initialized)
        );
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_RevertsWhenUnreachableFarTick(
        InitDataParams memory params,
        bool isToken0,
        int24 farTick
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitData(params);
        vm.assume(farTick > TickMath.MIN_TICK && farTick < TickMath.MAX_TICK);
        vm.assume(farTick < 160_000 || farTick > 240_000);
        initData.farTick = farTick;
        vm.expectRevert(UnreachableFarTick.selector);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_InitializesPool(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) returns (InitData memory initData) {
        initData = _prepareInitData(params);

        vm.expectEmit();
        emit IPoolInitializer.Create(address(manager), asset, numeraire);

        vm.prank(address(airlock));
        address returnedAsset =
            initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
        assertEq(returnedAsset, asset, "Returned asset address is incorrect");

        (,,,, PoolStatus status,,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be Initialized");
    }

    function test_initialize_LocksPool(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) returns (InitData memory initData) {
        initData = _prepareInitDataLock(params);

        vm.expectEmit();
        emit Lock(asset, initData.beneficiaries);
        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        (,,,, PoolStatus status,,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Locked), "Pool status should be locked");

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < initData.beneficiaries.length; i++) {
            assertEq(beneficiaries[i].beneficiary, initData.beneficiaries[i].beneficiary, "Incorrect beneficiary");
            assertEq(beneficiaries[i].shares, initData.beneficiaries[i].shares, "Incorrect shares");
        }
    }

    function test_initialize_LocksPoolWithDopplerHook(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) returns (InitData memory initData) {
        initData = _prepareInitDataWithDopplerHook(params);

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));

        (,, address dopplerHookAddress, bytes memory graduationDopplerHookCalldata,, PoolKey memory key,,) =
            initializer.getState(asset);
        assertEq32(PoolId.unwrap(key.toId()), PoolId.unwrap(poolId), "Pool Ids not matching");
        assertEq(dopplerHookAddress, address(dopplerHook), "Incorrect dopplerHook address");
        assertEq(
            graduationDopplerHookCalldata,
            initData.graduationDopplerHookCalldata,
            "Incorrect graduation dopplerHook calldata"
        );
    }

    function test_initialize_CallsDopplerHookOnInitialization(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDopplerHook(params);

        vm.prank(address(airlockOwner));
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(dopplerHook);
        flags[0] = ON_INITIALIZATION_FLAG | ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);

        vm.expectCall(
            address(dopplerHook),
            abi.encodeWithSelector(
                IDopplerHook.onInitialization.selector, asset, poolKey, initData.onInitializationDopplerHookCalldata
            )
        );

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_DoesNotCallDopplerHookOnInitializationWhenFlagIsOff(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDopplerHook(params);

        vm.prank(address(airlockOwner));
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(dopplerHook);
        flags[0] = ON_GRADUATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);

        vm.expectCall(
            address(dopplerHook),
            abi.encodeWithSelector(
                IDopplerHook.onInitialization.selector, asset, initData.onInitializationDopplerHookCalldata
            ),
            0
        );

        vm.prank(address(airlock));
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function test_initialize_StoresPoolState(InitDataParams memory params, bool isToken0) public {
        InitData memory initData = test_initialize_InitializesPool(params, isToken0);

        (address returnedNumeraire,,,, PoolStatus status, PoolKey memory key, int24 farTick,) =
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

    function test_exitLiquidity(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);

        (,,,,,,int24 farTick,) = initializer.getState(asset);
        _buyUntilFarTick(isToken0);
        vm.prank(address(airlock));
        (uint160 sqrtPriceX96,,,,,,) = initializer.exitLiquidity(asset);

        // TODO: Check if the currentTick is at least the farTick
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(farTick), "Incorrect returned sqrtPriceX96");

        (,,,, PoolStatus status,,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Exited), "Pool status should be Exited");

        assertEq(currency0.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token0");
        assertEq(currency1.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token1");

        assertLt(currency0.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token0");
        assertLt(currency1.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token1");

        assertEq(manager.getLiquidity(poolId), 0, "Pool liquidity should be zero");
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolAlreadyExited(InitDataParams memory params, bool isToken0) public {
        test_exitLiquidity(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Exited));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolIsLocked(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Locked));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenPoolGraduated(InitDataParams memory params, bool isToken0) public {
        test_graduate_GraduatesPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Graduated));
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);
        (,,,,,, int24 farTick,) = initializer.getState(asset);
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

    function test_collectFees(InitDataParams memory initParams, bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataLock(initParams);
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
        vm.expectEmit();
        emit DelegateAuthority(user, delegation);
        vm.prank(user);
        initializer.delegateAuthority(delegation);
        assertEq(initializer.getAuthority(user), delegation, "Incorrect delegated authority");
    }

    /* ---------------------------------------------------------------------------- */
    /*                                setDopplerHookState()                                */
    /* ---------------------------------------------------------------------------- */

    function test_setDopplerHookState_RevertsWhenSenderNotAirlockOwner(
        address[] calldata dopplerHooks,
        uint256[] calldata flags
    ) public {
        vm.expectRevert(SenderNotAirlockOwner.selector);
        initializer.setDopplerHookState(dopplerHooks, flags);
    }

    function test_setDopplerHookState_RevertsWhenArrayLengthsMismatch(
        address[] calldata dopplerHooks,
        uint256[] calldata flags
    ) public {
        vm.assume(dopplerHooks.length != flags.length);
        vm.prank(airlockOwner);
        vm.expectRevert(ArrayLengthsMismatch.selector);
        initializer.setDopplerHookState(dopplerHooks, flags);
    }

    // TODO: Refactor this function so unique addresses are generated instead of expecting unique
    // addresses from the fuzzer directly, this should reduce the number of discarded runs
    function test_setDopplerHookState_SetsStates(address[] calldata dopplerHooks, uint256[] calldata flags) public {
        uint256 length = dopplerHooks.length;
        vm.assume(length == flags.length);
        vm.assume(length < 50); // Limit size to avoid timeout

        // Ensure all addresses are unique to avoid overwriting in the mapping
        for (uint256 i; i < length; i++) {
            for (uint256 j = i + 1; j < length; j++) {
                vm.assume(dopplerHooks[i] != dopplerHooks[j]);
            }
        }

        for (uint256 i; i < length; i++) {
            vm.expectEmit();
            emit SetDopplerHookState(dopplerHooks[i], flags[i]);
        }

        vm.prank(airlockOwner);
        initializer.setDopplerHookState(dopplerHooks, flags);

        for (uint256 i; i < length; i++) {
            uint256 storedFlags = initializer.isDopplerHookEnabled(dopplerHooks[i]);
            assertEq(storedFlags, flags[i], "Incorrect stored flags");
        }
    }

    /* ----------------------------------------------------------------------- */
    /*                                setDopplerHook()                                */
    /* ----------------------------------------------------------------------- */

    function test_setDopplerHook_RevertsIfPoolNotLocked(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.setDopplerHook(asset, address(dopplerHook), new bytes(0), new bytes(0));
    }

    function test_setDopplerHook_RevertsWhenSenderNotAuthorized(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPool(params, isToken0);
        vm.expectRevert(SenderNotAuthorized.selector);
        vm.prank(address(0xbeef));
        initializer.setDopplerHook(asset, address(dopplerHook), new bytes(0), new bytes(0));
    }

    function test_setDopplerHook_RevertsWhenDopplerHookNotEnabled(
        InitDataParams memory params,
        bool isToken0
    ) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataWithDopplerHook(params);
        initData.dopplerHook = address(0xdeadbeef);
        vm.prank(address(airlock));
        vm.expectRevert(DopplerHookNotEnabled.selector);
        initializer.initialize(asset, numeraire, totalTokensOnBondingCurve, 0, abi.encode(initData));
    }

    function _setDopplerHook(bytes calldata onInitializationCalldata, bytes calldata onGraduationCalldata) public {
        vm.expectCall(
            address(dopplerHook),
            abi.encodeWithSelector(IDopplerHook.onInitialization.selector, asset, poolKey, onInitializationCalldata)
        );
        vm.expectEmit();
        emit SetDopplerHook(asset, address(dopplerHook));
        initializer.setDopplerHook(asset, address(dopplerHook), onInitializationCalldata, onGraduationCalldata);

        (,, address dopplerHookAddress, bytes memory storedOnGraduationCalldata,,,,) = initializer.getState(asset);
        assertEq(dopplerHookAddress, address(dopplerHook), "Incorrect dopplerHook address");
        assertEq(storedOnGraduationCalldata, onGraduationCalldata, "Incorrect graduation dopplerHook calldata");
    }

    function test_setDopplerHook_SetsDopplerHookWhenSenderIsTimelock(
        InitDataParams memory params,
        bool isToken0,
        bytes calldata onInitializationCalldata,
        bytes calldata onGraduationCalldata
    ) public {
        test_initialize_LocksPool(params, isToken0);

        vm.mockCall(
            address(airlock),
            abi.encodeWithSelector(0x1652e7b7, asset),
            abi.encode(
                address(0), address(this), address(0), address(0), address(0), address(0), address(0), 0, 0, address(0)
            )
        );

        _setDopplerHook(onInitializationCalldata, onGraduationCalldata);
    }

    function test_setDopplerHook_SetsDopplerHookWhenSenderIsAuthority(
        InitDataParams memory params,
        bool isToken0,
        bytes calldata onInitializationCalldata,
        bytes calldata onGraduationCalldata
    ) public {
        test_initialize_LocksPool(params, isToken0);

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

        _setDopplerHook(onInitializationCalldata, onGraduationCalldata);
    }

    /* ------------------------------------------------------------------------ */
    /*                                graduate()                                */
    /* ------------------------------------------------------------------------ */

    function test_graduate_RevertsWhenPoolNotLocked(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.graduate(asset);
    }

    function test_graduate_RevertsWhenNoProvidedDopplerHook(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPool(params, isToken0);
        vm.expectRevert(CannotMigratePoolNoProvidedDopplerHook.selector);
        initializer.graduate(asset);
    }

    function test_graduate_GraduatesPool(InitDataParams memory params, bool isToken0) public {
        InitData memory initData = test_initialize_LocksPoolWithDopplerHook(params, isToken0);
        _buyUntilFarTick(isToken0);

        vm.expectCall(
            address(dopplerHook),
            abi.encodeWithSelector(
                MockDopplerHook.onGraduation.selector, asset, poolKey, initData.graduationDopplerHookCalldata
            )
        );

        vm.expectEmit();
        emit Graduate(asset);

        vm.prank(address(airlock));
        initializer.graduate(asset);

        (,,,, PoolStatus status,,,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Graduated), "Pool status should be Graduated");
    }

    function test_graduate_RevertsWhenAlreadyGraduated(InitDataParams memory params, bool isToken0) public {
        test_graduate_GraduatesPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Graduated));

        vm.prank(address(airlock));
        initializer.graduate(asset);
    }

    function test_graduate_RevertsWhenFarTickNotReached(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPoolWithDopplerHook(params, isToken0);
        (,,,,,, int24 farTick,) = initializer.getState(asset);
        (, int24 tick,,) = manager.getSlot0(poolId);
        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, farTick, tick));
        initializer.graduate(asset);
    }

    /* ---------------------------------------------------------------------------------- */
    /*                                updateDynamicLPFee()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_updateDynamicLPFee_RevertsWhenSenderNotDopplerHook(
        InitDataParams memory params,
        bool isToken0
    ) public {
        test_initialize_LocksPoolWithDopplerHook(params, isToken0);
        vm.expectRevert(SenderNotAuthorized.selector);
        vm.prank(address(0xbeef));
        initializer.updateDynamicLPFee(asset, 100);
    }

    function test_updateDynamicLPFee_RevertsWhenPoolWrongStatus(InitDataParams memory params, bool isToken0) public {
        test_initialize_InitializesPool(params, isToken0);
        vm.expectRevert(abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Locked, PoolStatus.Initialized));
        initializer.updateDynamicLPFee(asset, 100);
    }

    function test_updateDynamicLPFee_UpdatesFee(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPoolWithDopplerHook(params, isToken0);
        vm.prank(address(dopplerHook));
        initializer.updateDynamicLPFee(asset, 100);
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, 100, "Incorrect updated fee");
    }

    function test_updateDynamicLPFee_RevertsWhenFeeTooHigh(InitDataParams memory params, bool isToken0) public {
        test_initialize_LocksPoolWithDopplerHook(params, isToken0);
        vm.prank(address(dopplerHook));
        vm.expectRevert(abi.encodeWithSelector(LPFeeTooHigh.selector, MAX_LP_FEE, MAX_LP_FEE + 1));
        initializer.updateDynamicLPFee(asset, MAX_LP_FEE + 1);
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

    /* --------------------------------------------------------------------------------- */
    /*                                afterAddLiquidity()                                */
    /* --------------------------------------------------------------------------------- */

    function test_afterAddLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.afterAddLiquidity(
            address(0),
            key,
            IPoolManager.ModifyLiquidityParams(0, 0, 0, 0),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterAddLiquidity_PassesWhenMsgSenderPoolManager(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) public {
        vm.expectEmit();
        emit ModifyLiquidity(key, params);

        vm.prank(address(manager));
        initializer.afterAddLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* ------------------------------------------------------------------------- */
    /*                                afterSwap()                                */
    /* ------------------------------------------------------------------------- */

    function test_afterSwap_RevertsWhenMsgSenderNotPoolManager(PoolKey calldata key) public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.afterSwap(
            address(0),
            key,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0 }),
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterSwap_PassesWhenMsgSenderPoolManager(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta balanceDelta,
        bytes calldata hookData
    ) public {
        vm.expectEmit();
        emit Swap(address(this), key, key.toId(), params, balanceDelta.amount0(), balanceDelta.amount1(), hookData);
        vm.prank(address(manager));
        initializer.afterSwap(address(this), key, params, balanceDelta, hookData);
    }

    function test_afterSwap_CallsOnSwapWhenDopplerHookSet(
        InitDataParams memory initParams,
        bool isToken0,
        address sender,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta balanceDelta,
        bytes calldata data
    ) public {
        test_initialize_LocksPoolWithDopplerHook(initParams, isToken0);
        vm.expectCall(
            address(dopplerHook),
            abi.encodeWithSelector(IDopplerHook.onSwap.selector, sender, poolKey, swapParams, balanceDelta, data)
        );
        vm.prank(address(manager));
        initializer.afterSwap(sender, poolKey, swapParams, balanceDelta, data);
    }

    /* ------------------------------------------------------------------------------------ */
    /*                                afterRemoveLiquidity()                                */
    /* ------------------------------------------------------------------------------------ */

    function test_afterRemoveLiquidity_RevertsWhenMsgSenderNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        initializer.afterRemoveLiquidity(
            address(0),
            key,
            IPoolManager.ModifyLiquidityParams(0, 0, 0, 0),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            new bytes(0)
        );
    }

    function test_afterRemoveLiquidity_EmitsModifyLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) public {
        vm.expectEmit();
        emit ModifyLiquidity(key, params);
        vm.prank(address(manager));
        initializer.afterRemoveLiquidity(
            address(0), key, params, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0)
        );
    }

    /* ----------------------------------------------------------------------- */
    /*                                Utilities                                */
    /* ----------------------------------------------------------------------- */

    /// @dev This struct is used so we can get random parameters from the fuzzer
    struct InitDataParams {
        int24 tickSpacing;
    }

    function _prepareInitData(InitDataParams memory params) internal returns (InitData memory) {
        vm.assume(params.tickSpacing >= TickMath.MIN_TICK_SPACING && params.tickSpacing <= TickMath.MAX_TICK_SPACING);

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
            dopplerHook: address(0),
            onInitializationDopplerHookCalldata: new bytes(0),
            graduationDopplerHookCalldata: new bytes(0),
            farTick: 200_000
        });
    }

    function _prepareInitDataLock(InitDataParams memory params) internal returns (InitData memory) {
        InitData memory initData = _prepareInitData(params);
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05e18 });
        initData.beneficiaries = beneficiaries;
        return initData;
    }

    function _prepareInitDataWithDopplerHook(InitDataParams memory params) internal returns (InitData memory) {
        InitData memory initData = _prepareInitDataLock(params);
        initData.dopplerHook = address(dopplerHook);
        initData.graduationDopplerHookCalldata = abi.encode(0xbeef);
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
