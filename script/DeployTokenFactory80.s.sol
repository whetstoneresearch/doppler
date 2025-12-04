// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { TokenFactory80 } from "src/tokens/TokenFactory80.sol";

contract DeployTokenFactory80Script is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        bytes32 salt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xbeef));

        vm.startBroadcast();
        address tokenFactory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(TokenFactory80).creationCode, abi.encode(airlock)));

        console.log("TokenFactory80 deployed to:", address(tokenFactory));
        config.set("token_factory_80", address(tokenFactory));
        vm.stopBroadcast();
    }
}
