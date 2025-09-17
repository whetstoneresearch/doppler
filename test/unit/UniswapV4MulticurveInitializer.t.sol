// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import {
    UniswapV4MulticurveInitializer,
    InitData,
    BeneficiaryData,
    CannotMigrateInsufficientTick,
    PoolAlreadyInitialized,
    PoolStatus,
    PoolNotLocked,
    PoolAlreadyExited
} from "src/UniswapV4MulticurveInitializer.sol";
import { WAD } from "src/types/Wad.sol";
import { Position } from "src/types/Position.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { Airlock } from "src/Airlock.sol";

contract UniswapV4MulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public hook;
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        airlock = new Airlock(airlockOwner);
        currency0.transfer(address(airlock), currency0.balanceOfSelf());
        // currency1.transfer(address(airlock), currency1.balanceOfSelf());
        hook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new UniswapV4MulticurveInitializer(address(airlock), manager, hook);

        vm.startPrank(address(airlock));
        ERC20(Currency.unwrap(currency0)).approve(address(initializer), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(initializer), type(uint256).max);
        vm.stopPrank();

        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(hook));
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    // constructor() //

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(airlock));
        assertEq(address(initializer.poolManager()), address(manager));
        assertEq(address(initializer.hook()), address(hook));
    }

    // initialize() //

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        InitData memory initData = _prepareInitData();
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), 1e27, bytes32(0), abi.encode(initData)
        );
    }

    function test_initialize_RevertsWhenAlreadyInitialized() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );
        vm.expectRevert(PoolAlreadyInitialized.selector);
        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), 1e27, bytes32(0), abi.encode(initData)
        );
    }

    function test_initialize_AddsLiquidity() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0, "Liquidity is zero");
    }

    function test_initialize_InitializesPool() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        (, PoolStatus status,,) = initializer.getState(Currency.unwrap(currency0));
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be Initialized");
    }

    function test_initialize_LocksPool() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitDataLock();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        (, PoolStatus status,,) = initializer.getState(Currency.unwrap(currency0));
        assertEq(uint8(status), uint8(PoolStatus.Locked), "Pool status should be locked");

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(Currency.unwrap(currency0));

        for (uint256 i; i < initData.beneficiaries.length; i++) {
            assertEq(beneficiaries[i].beneficiary, initData.beneficiaries[i].beneficiary, "Incorrect beneficiary");
            assertEq(beneficiaries[i].shares, initData.beneficiaries[i].shares, "Incorrect shares");
        }
    }

    function test_initialize_StoresPoolState() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        (address numeraire, PoolStatus status, PoolKey memory key, int24 farTick) =
            initializer.getState(Currency.unwrap(currency0));
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status should be initialized");

        assertEq(numeraire, Currency.unwrap(currency1), "Incorrect numeraire");
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(currency0), "Incorrect currency0");
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(currency1), "Incorrect currency1");
        assertEq(key.fee, initData.fee, "Incorrect fee");
        assertEq(key.tickSpacing, initData.tickSpacing, "Incorrect tick spacing");
        assertEq(address(key.hooks), address(hook), "Incorrect hook");
        assertEq(farTick, 240_000, "Incorrect far tick");
    }

    // exitLiquidity() //

    function test_exitLiquidity() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        vm.prank(address(airlock));
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );
        (,,, int24 farTick) = initializer.getState(Currency.unwrap(currency0));
        _buyUntilFarTick(totalTokensOnBondingCurve, farTick, true);
        vm.prank(address(airlock));
        (uint160 sqrtPriceX96,,,,,,) = initializer.exitLiquidity(Currency.unwrap(currency0));

        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(farTick), "Incorrect returned sqrtPriceX96");

        (, PoolStatus status,,) = initializer.getState(Currency.unwrap(currency0));
        assertEq(uint8(status), uint8(PoolStatus.Exited), "Pool status should be Exited");

        assertEq(currency0.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token0");
        assertEq(currency1.balanceOf(address(initializer)), 0, "Initializer should have zero balance of token1");

        assertLt(currency0.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token0");
        assertLt(currency1.balanceOf(address(manager)), 100, "Poolmanager should have zero balance of token1");

        assertEq(manager.getLiquidity(poolId), 0, "Pool liquidity should be zero");

        Position[] memory positions = initializer.getPositions(Currency.unwrap(currency0));

        for (uint256 i; i < positions.length; i++) {
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(initializer), positions[i].tickLower, positions[i].tickUpper, positions[i].salt
            );
            assertEq(liquidity, 0, "Position liquidity should be zero");
        }
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock() public {
        test_initialize_AddsLiquidity();
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    function test_exitLiquidity_RevertsWhenPoolNotInitialized() public {
        test_exitLiquidity();
        vm.expectRevert(PoolAlreadyExited.selector);
        vm.prank(address(airlock));
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick() public {
        test_initialize_AddsLiquidity();
        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, 240_000, 160_000));
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    // collectFees() //

    function test_collectFees_RevertsWhenPoolNotLocked() public {
        vm.expectRevert(PoolNotLocked.selector);
        initializer.collectFees(PoolId.wrap(0));
    }

    // Utils //

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

        return InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: beneficiaries });
    }

    function _prepareInitDataLock() internal returns (InitData memory) {
        InitData memory initData = _prepareInitData();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05e18 });
        initData.beneficiaries = beneficiaries;
        return initData;
    }

    function _buyUntilFarTick(uint256 totalTokensOnBondingCurve, int24 farTick, bool isToken0) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(totalTokensOnBondingCurve),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        if (isToken0) {
            ERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        } else {
            ERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        }

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
        (, int24 tick,,) = manager.getSlot0(poolId);
        assertTrue(((isToken0 && tick >= farTick) || (!isToken0 && tick <= farTick)), "Did not reach far tick");
    }
}
