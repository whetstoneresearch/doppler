// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { LockableUniswapV3Initializer } from "src/LockableUniswapV3Initializer.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";

abstract contract DeployMegaETHTestnetScript is Script {
    function run() public {
        vm.startBroadcast();

        // Airlock
        Airlock airlock = new Airlock(msg.sender);

        // Pool Initializer modules
        LockableUniswapV3Initializer lockableUniswapV3Initializer = new LockableUniswapV3Initializer(
            address(airlock), IUniswapV3Factory(0x09EBEA59542086Fb181AD6EF4bBaAEf497Df88E8)
        );

        // Governance Factory modules
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        // Liquidity Migrator modules
        NoOpMigrator noOpMigrator = new NoOpMigrator(address(airlock));

        // Whitelisting the initial modules
        address[] memory modules = new address[](3);
        modules[0] = address(lockableUniswapV3Initializer);
        modules[1] = address(noOpGovernanceFactory);
        modules[2] = address(noOpMigrator);

        ModuleState[] memory states = new ModuleState[](3);
        states[0] = ModuleState.PoolInitializer;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.LiquidityMigrator;

        Airlock(payable(airlock)).setModuleState(modules, states);

        // Deploy the Airlock Multisig and transfer ownership to it
        address[] memory signers = new address[](1);
        signers[0] = msg.sender;

        AirlockMultisig airlockMultisig = new AirlockMultisig(airlock, signers);

        airlock.transferOwnership(address(airlockMultisig));

        vm.stopBroadcast();
    }
}
