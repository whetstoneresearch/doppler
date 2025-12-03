// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/Console.sol";
import { Script } from "forge-std/Script.sol";
import { ICreateX } from "script/ICreateX.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";

contract DeployCloneERC20FactoryScript is Script, Config {
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
        address cloneERC20Factory = ICreateX(createX)
            .deployCreate3(salt, abi.encodePacked(type(CloneERC20Factory).creationCode, abi.encode(airlock)));

        console.log("CloneERC20Factory deployed to:", address(cloneERC20Factory));
        config.set("clone_erc20_factory", address(cloneERC20Factory));
        vm.stopBroadcast();
    }
}
