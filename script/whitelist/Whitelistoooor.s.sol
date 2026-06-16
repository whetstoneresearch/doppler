// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { ModuleState } from "src/Airlock.sol";

contract WhitelistoooorScript is Script, Config {
    function run() public {
        _loadConfig("./deployments.config.toml", true);

        address airlock = config.get("airlock").toAddress();
        address airlockMultisig = config.get("airlock_multisig").toAddress();

        uint256 moduleCount = _moduleCount();
        address[] memory modules = new address[](moduleCount);
        ModuleState[] memory states = new ModuleState[](moduleCount);

        uint256 index;
        index = _appendModule(modules, states, index, "doppler_erc20_v1_factory", ModuleState.TokenFactory);
        index = _appendModule(modules, states, index, "dn404_factory", ModuleState.TokenFactory);
        index = _appendModule(modules, states, index, "no_op_governance_factory", ModuleState.GovernanceFactory);
        index = _appendModule(modules, states, index, "governance_factory", ModuleState.GovernanceFactory);
        index = _appendModule(modules, states, index, "launchpad_governance_factory", ModuleState.GovernanceFactory);
        index = _appendModule(modules, states, index, "doppler_hook_initializer", ModuleState.PoolInitializer);
        index = _appendModule(modules, states, index, "uniswap_v4_initializer", ModuleState.PoolInitializer);
        index = _appendModule(modules, states, index, "lockable_uniswap_v3_initializer", ModuleState.PoolInitializer);
        index = _appendModule(modules, states, index, "no_op_migrator", ModuleState.LiquidityMigrator);
        index = _appendModule(modules, states, index, "uniswap_v2_migrator_split", ModuleState.LiquidityMigrator);
        index = _appendModule(modules, states, index, "doppler_hook_migrator", ModuleState.LiquidityMigrator);
        require(index == moduleCount, "Module count mismatch");

        vm.startBroadcast();
        AirlockMultisigTestnet(airlockMultisig).setModuleState(payable(airlock), modules, states);
        vm.stopBroadcast();
    }

    function _moduleCount() internal view returns (uint256 count) {
        count += _moduleExists("doppler_erc20_v1_factory");
        count += _moduleExists("dn404_factory");
        count += _moduleExists("no_op_governance_factory");
        count += _moduleExists("governance_factory");
        count += _moduleExists("launchpad_governance_factory");
        count += _moduleExists("doppler_hook_initializer");
        count += _moduleExists("uniswap_v4_initializer");
        count += _moduleExists("lockable_uniswap_v3_initializer");
        count += _moduleExists("no_op_migrator");
        count += _moduleExists("uniswap_v2_migrator_split");
        count += _moduleExists("doppler_hook_migrator");
    }

    function _moduleExists(string memory key) internal view returns (uint256) {
        return config.exists(key) ? 1 : 0;
    }

    function _appendModule(
        address[] memory modules,
        ModuleState[] memory states,
        uint256 index,
        string memory key,
        ModuleState state
    ) internal view returns (uint256) {
        if (!config.exists(key)) return index;

        modules[index] = config.get(key).toAddress();
        states[index] = state;
        return index + 1;
    }
}
