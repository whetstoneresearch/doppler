// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey, IHooks, BalanceDelta } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import {
    UniswapV4MulticurveInitializer,
    InitData,
    BeneficiaryData,
    WAD,
    CannotMigrateInsufficientTick
} from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";

contract UniswapV4MulticurveInitializerTest is Deployers {
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public hook;
    address public airlock = makeAddr("airlock");

    function setUp() public {
        deployFreshManager();
        (currency0, currency1) = deployAndMint2Currencies();
        hook = UniswapV4MulticurveInitializerHook(address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144)));
        initializer = new UniswapV4MulticurveInitializer(airlock, manager, hook);
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(hook));
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), airlock);
        assertEq(address(initializer.poolManager()), address(manager));
        assertEq(address(initializer.hook()), address(hook));
    }

    function test_initialize() public {
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

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);

        uint256 totalTokensOnBondingCurve = 1e27;

        InitData memory initData = InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            numPositions: numPositions,
            shareToBeSold: shareToBeSold,
            beneficiaries: beneficiaries
        });

        currency0.transfer(address(initializer), totalTokensOnBondingCurve);
        vm.prank(airlock);
        initializer.initialize(
            Currency.unwrap(currency0), Currency.unwrap(currency1), totalTokensOnBondingCurve, 0, abi.encode(initData)
        );
    }

    function test_exitLiquidity_RevertsWhenInsufficientTick() public {
        test_initialize();
        vm.prank(airlock);
        vm.expectRevert(abi.encodeWithSelector(CannotMigrateInsufficientTick.selector, 240_000, TickMath.MIN_TICK));
        initializer.exitLiquidity(Currency.unwrap(currency0));
    }
}
