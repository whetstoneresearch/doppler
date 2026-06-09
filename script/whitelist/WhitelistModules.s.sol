// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";

/**
 * @title WhitelistModulesScript
 * @notice Script to whitelist modules on any chain
 * @dev This script can be used to whitelist modules after they've been deployed
 *
 * Usage:
 * forge script script/WhitelistModules.s.sol:WhitelistModulesScript \
 *   --sig "run(address,address[],uint8[])" \
 *   <AIRLOCK_ADDRESS> \
 *   "[<MODULE1>,<MODULE2>]" \
 *   "[<STATE1>,<STATE2>]" \
 *   --rpc-url <RPC_URL> \
 *   --broadcast
 *
 * ModuleState values:
 * 0 = NotWhitelisted
 * 1 = TokenFactory
 * 2 = GovernanceFactory
 * 3 = PoolInitializer
 * 4 = LiquidityMigrator
 */
contract WhitelistModulesScript is Script {
    function run(address airlockAddress, address[] calldata modules, uint8[] calldata states) public {
        console.log(unicode"🔐 Whitelisting modules on chain %s...", vm.toString(block.chainid));
        console.log("Airlock address: %s", airlockAddress);
        console.log("Number of modules to whitelist: %s", modules.length);

        require(modules.length == states.length, "Modules and states arrays must have the same length");
        require(modules.length > 0, "Must provide at least one module to whitelist");

        Airlock airlock = Airlock(payable(airlockAddress));

        // Convert uint8 array to ModuleState array
        ModuleState[] memory moduleStates = new ModuleState[](states.length);
        for (uint256 i = 0; i < states.length; i++) {
            require(states[i] <= uint8(ModuleState.LiquidityMigrator), "Invalid module state");
            moduleStates[i] = ModuleState(states[i]);

            console.log("Module %s: %s -> %s", i + 1, modules[i], _getModuleStateName(moduleStates[i]));
        }

        vm.startBroadcast();

        // Check current owner
        address owner = airlock.owner();
        console.log("Current Airlock owner: %s", owner);
        console.log("Transaction sender: %s", msg.sender);

        if (owner != msg.sender) {
            console.log(unicode"⚠️  WARNING: Sender is not the owner. This transaction will likely fail!");
        }

        airlock.setModuleState(modules, moduleStates);

        console.log(unicode"✅ Modules successfully whitelisted!");

        vm.stopBroadcast();
    }

    function _getModuleStateName(ModuleState state) internal pure returns (string memory) {
        if (state == ModuleState.NotWhitelisted) return "NotWhitelisted";
        if (state == ModuleState.TokenFactory) return "TokenFactory";
        if (state == ModuleState.GovernanceFactory) return "GovernanceFactory";
        if (state == ModuleState.PoolInitializer) return "PoolInitializer";
        if (state == ModuleState.LiquidityMigrator) return "LiquidityMigrator";
        return "Unknown";
    }
}

/**
 * @title WhitelistSingleModuleScript
 * @notice Convenience script to whitelist a single module
 * @dev Wrapper around WhitelistModulesScript for single module whitelisting
 *
 * Usage:
 * forge script script/WhitelistModules.s.sol:WhitelistSingleModuleScript \
 *   --sig "run(address,address,uint8)" \
 *   <AIRLOCK_ADDRESS> \
 *   <MODULE_ADDRESS> \
 *   <MODULE_STATE> \
 *   --rpc-url <RPC_URL> \
 *   --broadcast
 */
contract WhitelistSingleModuleScript is WhitelistModulesScript {
    function run(address airlockAddress, address module, uint8 state) public {
        address[] memory modules = new address[](1);
        modules[0] = module;

        uint8[] memory states = new uint8[](1);
        states[0] = state;

        this.run(airlockAddress, modules, states);
    }
}
