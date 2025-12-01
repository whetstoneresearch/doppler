// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Vm } from "forge-std/Vm.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import {
    DEFAULT_EPOCH_LENGTH,
    DEFAULT_GAMMA,
    DEFAULT_MAXIMUM_PROCEEDS,
    DEFAULT_MINIMUM_PROCEEDS
} from "test/shared/DopplerFixtures.sol";

int24 constant DEFAULT_START_TICK = 6000;
int24 constant DEFAULT_END_TICK = 60_000;
uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;

function deployUniswapV4Initializer(
    Vm vm,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (DopplerDeployer deployer, UniswapV4Initializer initializer) {
    deployer = new DopplerDeployer(IPoolManager(poolManager));
    initializer = new UniswapV4Initializer(address(airlock), IPoolManager(poolManager), deployer);
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

function preparePoolInitializerData(
    address airlock,
    address poolManager,
    address tokenFactory,
    bytes memory tokenFactoryData,
    address poolInitializer
) view returns (bytes32 salt, bytes memory poolInitializerData) {
    poolInitializerData = abi.encode(
        0.01 ether,
        10 ether,
        block.timestamp,
        block.timestamp + 1 days,
        DEFAULT_START_TICK,
        DEFAULT_END_TICK,
        200,
        800,
        false,
        10,
        200,
        2
    );

    uint256 initialSupply = 1e23;
    uint256 numTokensToSell = 1e23;

    MineV4Params memory params = MineV4Params({
        airlock: airlock,
        poolManager: poolManager,
        initialSupply: initialSupply,
        numTokensToSell: numTokensToSell,
        numeraire: address(0),
        tokenFactory: ITokenFactory(address(tokenFactory)),
        tokenFactoryData: tokenFactoryData,
        poolInitializer: UniswapV4Initializer(poolInitializer),
        poolInitializerData: poolInitializerData
    });

    (salt,,) = mineV4(params);
}
