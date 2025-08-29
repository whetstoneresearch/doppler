// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/Console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
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
    WAD,
    CannotMigrateInsufficientTick,
    PoolAlreadyInitialized,
    PoolStatus,
    PoolState,
    PoolLocked
} from "src/UniswapV4MulticurveInitializer.sol";
import { Position } from "src/types/Position.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";

contract UniswapV4MulticurveInitializerTest is Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public hook;
    address public airlock = makeAddr("Airlock");

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();
        hook = UniswapV4MulticurveInitializerHook(address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144)));
        initializer = new UniswapV4MulticurveInitializer(airlock, manager, hook);
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(hook));
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    // constructor() //

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), airlock);
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

        currency0.transfer(address(initializer), totalTokensOnBondingCurve);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );
        vm.expectRevert(PoolAlreadyInitialized.selector);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), 1e27, bytes32(0), abi.encode(initData)
        );
    }

    function test_initialize_AddsLiquidity() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        currency0.transfer(address(initializer), totalTokensOnBondingCurve);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0, "Liquidity is zero");
    }

    function test_initialize_UpdatesState() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        currency0.transfer(address(initializer), totalTokensOnBondingCurve);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );

        (uint128 positionLiquidity,,) = manager.getPositionInfo(
            poolId,
            address(initializer),
            232_000,
            240_000,
            0x0000000000000000000000000000000000000000000000000000000000000063
        );

        console.log("positionLiquidity", positionLiquidity);

        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0, "Liquidity is zero");

        (, PoolStatus status,) = initializer.getState(Currency.unwrap(currency0));
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Incorrect status");
        // assertEq(numeraire, Currency.unwrap(currency0), "Incorrect numeraire");
    }

    // exitLiquidity() //

    function test_exitLiquidity() public {
        uint256 totalTokensOnBondingCurve = 1e27;
        InitData memory initData = _prepareInitData();

        currency0.transfer(address(initializer), totalTokensOnBondingCurve);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );
        _buyUntilFarTick(totalTokensOnBondingCurve, initData.tickUpper[initData.tickUpper.length - 1], true);
        vm.prank(airlock);
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock() public {
        test_initialize_AddsLiquidity();
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick() public {
        test_initialize_AddsLiquidity();
        vm.prank(airlock);
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, 240_000, TickMath.MIN_TICK));
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }

    // collectFees() //

    function test_collectFees_RevertsWhenPoolNotLocked() public {
        vm.expectRevert(PoolLocked.selector);
        initializer.collectFees(address(0));
    }

    // Utils //

    function _prepareInitData() internal returns (InitData memory) {
        int24 tickSpacing = 8;
        int24[] memory tickLower = new int24[](10);
        int24[] memory tickUpper = new int24[](10);
        uint16[] memory numPositions = new uint16[](10);
        uint256[] memory shareToBeSold = new uint256[](10);

        for (uint256 i; i < 10; ++i) {
            tickLower[i] = int24(uint24(160_000 + i * 8));
            tickUpper[i] = 240_000;
            numPositions[i] = 10;
            shareToBeSold[i] = WAD / 10;
        }

        poolKey = PoolKey({ currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: hook });
        poolId = poolKey.toId();
        console.logBytes32(PoolId.unwrap(poolId));

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            numPositions: numPositions,
            shareToBeSold: shareToBeSold,
            beneficiaries: beneficiaries
        });
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
