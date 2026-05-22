// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds, checkChainId } from "script/ChainIds.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";

contract WhitelistDN404FactoryV2BaseSepoliaScript is Script, Config {
    function run() public {
        checkChainId(ChainIds.BASE_SEPOLIA);
        _loadConfig("./deployments.config.toml", true);

        address airlock = config.get("airlock").toAddress();
        address airlockMultisig = config.get("airlock_multisig").toAddress();
        address dn404Factory = config.get("dn404_factory").toAddress();

        vm.startBroadcast();
        AirlockMultisigTestnet(airlockMultisig).setModuleState(payable(airlock), dn404Factory, ModuleState.TokenFactory);
        vm.stopBroadcast();

        require(
            Airlock(payable(airlock)).getModuleState(dn404Factory) == ModuleState.TokenFactory,
            "DN404Factory not whitelisted"
        );
    }
}
