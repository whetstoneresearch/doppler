// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import { Curve } from "src/libraries/MulticurveLibV2.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { DookMulticurveInitializer, InitData } from "src/DookMulticurveInitializer.sol";
import { DookMulticurveHook } from "src/DookMulticurveHook.sol";

function deployDookMulticurveInitializer(
    Vm vm,
    function(string memory, bytes memory, address) deployCodeTo,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (DookMulticurveHook hook, DookMulticurveInitializer initializer) {
    hook = DookMulticurveHook(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        )
    );
    initializer = new DookMulticurveInitializer(address(airlock), IPoolManager(poolManager), hook);
    deployCodeTo("DookMulticurveHook", abi.encode(address(poolManager), address(initializer)), address(hook));
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

function prepareDookMulticurveInitializerData(
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
        InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: new BeneficiaryData[](0),
            dook: address(0),
            onInitializationDookCalldata: new bytes(0),
            graduationDookCalldata: new bytes(0)
        })
    );
}
