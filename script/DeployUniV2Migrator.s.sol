// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";

contract DeployUniV2MigratorScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](2);
        targets[0] = ChainIds.ETH_MAINNET;
        targets[1] = ChainIds.ETH_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address uniswapV2Factory = config.get("uniswap_v2_factory").toAddress();
        address uniswapV2Router = config.get("uniswap_v2_router").toAddress();
        address airlockOwner = Airlock(payable(airlock)).owner();

        vm.startBroadcast();
        bytes32 salt = generateCreate3Salt(msg.sender, type(UniswapV2MigratorSplit).name);
        address deployedTo = computeCreate3Address(computeCreate3GuardedSalt(salt, msg.sender), createX);

        address migrator = ICreateX(createX)
            .deployCreate3(
                salt,
                abi.encodePacked(
                    type(UniswapV2MigratorSplit).creationCode,
                    abi.encode(airlock, uniswapV2Factory, uniswapV2Router, airlockOwner)
                )
            );

        require(migrator == deployedTo, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("uniswap_v2_migrator", migrator);
    }
}
