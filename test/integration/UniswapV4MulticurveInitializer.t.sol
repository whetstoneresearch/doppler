// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { Vm } from "forge-std/Vm.sol";

import { Airlock, ModuleState } from "src/Airlock.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { InitData, UniswapV4MulticurveInitializer } from "src/modules/initializers/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/modules/initializers/UniswapV4MulticurveInitializerHook.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

function deployUniswapV4MulticurveInitializer(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (UniswapV4MulticurveInitializerHook multicurveHook, UniswapV4MulticurveInitializer initializer) {
    multicurveHook = UniswapV4MulticurveInitializerHook(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        )
    );
    initializer = new UniswapV4MulticurveInitializer(address(airlock), IPoolManager(poolManager), multicurveHook);
    deployCodeTo(
        "UniswapV4MulticurveInitializerHook",
        abi.encode(address(poolManager), address(initializer)),
        address(multicurveHook)
    );
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

function prepareUniswapV4MulticurveInitializerData(
    address asset,
    address numeraire
) pure returns (bytes memory poolInitializerData) {
    Curve[] memory curves = new Curve[](10);
    int24 tickSpacing = 8;

    for (uint256 i; i < 10; ++i) {
        curves[i].tickLower = int24(uint24(0 + i * 16_000));
        curves[i].tickUpper = 240_000;
        curves[i].numPositions = 10;
        curves[i].shares = WAD / 10;
    }

    Currency currency0 = Currency.wrap(address(numeraire));
    Currency currency1 = Currency.wrap(address(asset));

    (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);
    poolInitializerData = abi.encode(
        InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: new BeneficiaryData[](0) })
    );
}
