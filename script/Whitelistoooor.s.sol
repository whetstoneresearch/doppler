// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";

contract WhitelistoooorScript is Script, Config {
    function run() public {
        _loadConfig("./deployments.config.toml", true);

        address airlock = config.get("airlock").toAddress();
        address airlockMultisig = config.get("airlock_multisig").toAddress();

        address cloneERC20Factory = config.get("clone_erc20_factory").toAddress();
        address cloneERC20VotesFactory = config.get("clone_erc20_votes_factory").toAddress();
        address noOpGovernanceFactory = config.get("no_op_governance_factory").toAddress();
        address uniswapV4ScheduledMulticurveInitializer =
            config.get("uniswap_v4_scheduled_multicurve_initializer").toAddress();
        address uniswapV4Initializer = config.get("uniswap_v4_initializer").toAddress();
        address dopplerHookInitializer = config.get("doppler_hook_initializer").toAddress();
        address noOpMigrator = config.get("no_op_migrator").toAddress();
        address uniswapV2Migrator = config.get("uniswap_v2_migrator").toAddress();
        address uniswapV4Migrator = config.get("uniswap_v4_migrator").toAddress();
        address dopplerHookInternalInitializer =
            config.exists("doppler_hook_internal_initializer") ? config.get("doppler_hook_internal_initializer").toAddress() : address(0);
        address linearDescendingFeeDopplerHook =
            config.exists("linear_descending_fee_doppler_hook") ? config.get("linear_descending_fee_doppler_hook").toAddress() : address(0);

        uint256 numModules = dopplerHookInternalInitializer != address(0) ? 10 : 9;
        address[] memory modules = new address[](numModules);
        ModuleState[] memory states = new ModuleState[](numModules);
        uint256 i;

        modules[i] = cloneERC20Factory;
        states[i++] = ModuleState.TokenFactory;
        modules[i] = cloneERC20VotesFactory;
        states[i++] = ModuleState.TokenFactory;
        modules[i] = noOpGovernanceFactory;
        states[i++] = ModuleState.GovernanceFactory;
        modules[i] = uniswapV4ScheduledMulticurveInitializer;
        states[i++] = ModuleState.PoolInitializer;
        modules[i] = uniswapV4Initializer;
        states[i++] = ModuleState.PoolInitializer;
        modules[i] = dopplerHookInitializer;
        states[i++] = ModuleState.PoolInitializer;
        modules[i] = noOpMigrator;
        states[i++] = ModuleState.LiquidityMigrator;
        modules[i] = uniswapV2Migrator;
        states[i++] = ModuleState.LiquidityMigrator;
        modules[i] = uniswapV4Migrator;
        states[i++] = ModuleState.LiquidityMigrator;

        if (dopplerHookInternalInitializer != address(0)) {
            modules[i] = dopplerHookInternalInitializer;
            states[i++] = ModuleState.PoolInitializer;
        }

        vm.startBroadcast();
        AirlockMultisigTestnet multisig = AirlockMultisigTestnet(airlockMultisig);
        multisig.setModuleState(payable(airlock), modules, states);

        if (dopplerHookInternalInitializer != address(0) && linearDescendingFeeDopplerHook != address(0)) {
            address[] memory dopplerHooks = new address[](1);
            dopplerHooks[0] = linearDescendingFeeDopplerHook;

            uint256[] memory flags = new uint256[](1);
            flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;

            multisig.setDopplerHookState(payable(dopplerHookInternalInitializer), dopplerHooks, flags);
        }
        vm.stopBroadcast();
    }
}
