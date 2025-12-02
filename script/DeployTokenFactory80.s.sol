// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/Console.sol";
import { Script } from "forge-std/Script.sol";
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

        vm.startBroadcast();
        address tokenFactory =
            ICreateX(config.get("create_x").toAddress()).deployCreate3(type(TokenFactory80).creationCode);
        console.log("TokenFactory80 deployed to:", address(tokenFactory));
        config.set("token_factory_80", address(tokenFactory));
        vm.stopBroadcast();
    }
}
