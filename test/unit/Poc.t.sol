// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager, PoolKey } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import {
    UniswapV4MulticurveInitializer,
    InitData,
    BeneficiaryData,
    CannotMigrateInsufficientTick,
    PoolAlreadyInitialized,
    PoolStatus,
    PoolNotLocked,
    PoolAlreadyExited,
    Lock
} from "src/UniswapV4MulticurveInitializer.sol";
import { WAD } from "src/types/Wad.sol";
import { Position } from "src/types/Position.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { Airlock } from "src/Airlock.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";
import { BeforeSwapPocHook } from "src/BeforeSwapPocHook.sol";

contract PocTest is Deployers {
    BeforeSwapPocHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = BeforeSwapPocHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        deployCodeTo("BeforeSwapPocHook", abi.encode(manager, address(this)), address(hook));
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    function test_poc() public {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(hook)), tickSpacing: 1
        });

        manager.initialize(key, Constants.SQRT_PRICE_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100, liquidityDelta: 0.001 ether, salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e15,
            sqrtPriceLimitX96: true ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }
}
