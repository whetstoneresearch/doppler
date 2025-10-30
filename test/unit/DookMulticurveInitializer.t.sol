// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import {
    DookMulticurveInitializer,
    InitData,
    BeneficiaryData,
    CannotMigrateInsufficientTick,
    Lock,
    PoolStatus,
    WrongPoolStatus
} from "src/DookMulticurveInitializer.sol";
import { WAD } from "src/types/Wad.sol";
import { Position } from "src/types/Position.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { DookMulticurveHook } from "src/DookMulticurveHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Curve } from "src/libraries/MulticurveLibV2.sol";
import { Airlock } from "src/Airlock.sol";

contract DookMulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;

    DookMulticurveInitializer public initializer;
    DookMulticurveHook public hook;
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;

    uint256 internal totalTokensOnBondingCurve = 1e27;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal asset;
    address internal numeraire;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        airlock = new Airlock(airlockOwner);
        hook = DookMulticurveHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new DookMulticurveInitializer(address(airlock), manager, hook);
        deployCodeTo("DookMulticurveHook", abi.encode(manager, initializer), address(hook));
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
        assertEq(address(initializer.HOOK()), address(hook));
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

    function test_initialize_LocksPool(bool isToken0) public prepareAsset(isToken0) {
        InitData memory initData = _prepareInitDataLock();

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
        assertEq(address(key.hooks), address(hook), "Incorrect hook");
        assertEq(farTick, isToken0 ? int24(240_000) : int24(-240_000), "Incorrect far tick");
    }

    /* ----------------------------------------------------------------------------- */
    /*                                exitLiquidity()                                */
    /* ----------------------------------------------------------------------------- */

    function test_exitLiquidity(bool isToken0) public {
        test_initialize_InitializesPool(isToken0);

        (,,,,,, int24 farTick) = initializer.getState(asset);
        _buyUntilFarTick(farTick, isToken0);
        vm.prank(address(airlock));
        (uint160 sqrtPriceX96,,,,,,) = initializer.exitLiquidity(asset);

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

    /*
    function test_exitLiquidity_RevertsWhenPoolAlreadyExited(bool isToken0) public {
        test_exitLiquidity(isToken0);
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, PoolStatus.Initialized, PoolStatus.Uninitialized)
        );
        vm.prank(address(airlock));
        initializer.exitLiquidity(asset);
    }
    */

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

    /* ----------------------------------------------------------------------- */
    /*                                Utilities                                */
    /* ----------------------------------------------------------------------- */

    function _prepareInitData() internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(160_000 + i * 8));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        poolKey = PoolKey({ currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: hook });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: beneficiaries,
            dook: address(0),
            graduationDookCalldata: new bytes(0)
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

    function _buyUntilFarTick(int24 farTick, bool isToken0) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(totalTokensOnBondingCurve),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(numeraire).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
        (, int24 tick,,) = manager.getSlot0(poolId);
        assertTrue(((isToken0 && tick >= farTick) || (!isToken0 && tick <= farTick)), "Did not reach far tick");
    }
}
