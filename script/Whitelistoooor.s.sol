// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";

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

        address[] memory modules = new address[](9);
        modules[0] = cloneERC20Factory;
        modules[1] = cloneERC20VotesFactory;
        modules[2] = noOpGovernanceFactory;
        modules[3] = uniswapV4ScheduledMulticurveInitializer;
        modules[4] = uniswapV4Initializer;
        modules[5] = dopplerHookInitializer;
        modules[6] = noOpMigrator;
        modules[7] = uniswapV2Migrator;
        modules[8] = uniswapV4Migrator;

        ModuleState[] memory states = new ModuleState[](9);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.TokenFactory;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.PoolInitializer;
        states[4] = ModuleState.PoolInitializer;
        states[5] = ModuleState.PoolInitializer;
        states[6] = ModuleState.LiquidityMigrator;
        states[7] = ModuleState.LiquidityMigrator;
        states[8] = ModuleState.LiquidityMigrator;

        vm.startBroadcast();
        AirlockMultisigTestnet(airlockMultisig).setModuleState(payable(airlock), modules, states);
        vm.stopBroadcast();
    }
}
