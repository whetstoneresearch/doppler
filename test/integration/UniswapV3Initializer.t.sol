// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { Vm } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import {
    CallbackData,
    CannotMigrateInsufficientTick,
    InitData,
    OnlyPool,
    PoolAlreadyExited,
    PoolAlreadyInitialized,
    UniswapV3Initializer
} from "src/UniswapV3Initializer.sol";
import { alignTick } from "src/libraries/TickLibrary.sol";

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = DEFAULT_UPPER_TICK - 16_260;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;

function deployUniswapV3Initializer(
    Vm vm,
    Airlock airlock,
    address uniswapV3Factory
) returns (UniswapV3Initializer initializer) {
    initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(uniswapV3Factory));
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlock.owner());
    airlock.setModuleState(modules, states);
}

// TODO: Fuzz these parameters
function prepareUniswapV3InitializerData(
    IUniswapV3Factory uniswapV3Factory,
    bool isToken0
) view returns (bytes memory) {
    int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(uint24(3000));
    int24 tickLower = alignTick(isToken0, isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK, tickSpacing);
    int24 tickUpper = alignTick(isToken0, isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK, tickSpacing);
    uint16 numPositions = 10;
    uint256 maxShareToBeSold = 0.9 ether;

    return abi.encode(
        InitData({
            fee: 3000,
            tickLower: tickLower,
            tickUpper: tickUpper,
            numPositions: numPositions,
            maxShareToBeSold: maxShareToBeSold
        })
    );
}

