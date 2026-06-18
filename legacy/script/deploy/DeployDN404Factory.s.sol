// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ICreateX } from "createx/ICreateX.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds, checkChainId } from "script/utils/ChainIds.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { DN404Factory } from "src/tokens/DN404Factory.sol";

contract DeployDN404FactoryBaseSepoliaScript is Script, Config {
    function run() public {
        checkChainId(ChainIds.BASE_SEPOLIA);
        _loadConfig("./deployments.config.toml", true);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();

        vm.startBroadcast();
        address deployer = tx.origin;
        bytes32 salt = generateCreate3Salt(deployer, type(DN404Factory).name);
        address expectedAddress = computeCreate3Address(computeCreate3GuardedSalt(salt, deployer), createX);

        address factory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(DN404Factory).creationCode, abi.encode(airlock)));
        require(factory == expectedAddress, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("dn404_factory", factory);
    }
}
