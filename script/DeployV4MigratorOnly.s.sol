/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import { mineV4MigratorHookCreate3 } from "test/shared/AirlockMiner.sol";

contract DeployV4MigratorOnlyScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        uint256[] memory targets = new uint256[](1);
        targets[0] = ChainIds.BASE_SEPOLIA;

        for (uint256 i; i < targets.length; i++) {
            uint256 chainId = targets[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();
        address positionManager = config.get("uniswap_v4_position_manager").toAddress();
        address topUpDistributor = config.get("top_up_distributor").toAddress();
        address locker = config.get("streamable_fees_locker").toAddress();

        vm.startBroadcast();
        (bytes32 hookSalt, address hookDeployedTo) = mineV4MigratorHookCreate3(msg.sender, createX);

        bytes32 migratorSalt = generateCreate3Salt(msg.sender, type(UniswapV4MigratorSplit).name);
        address migratorDeployedTo = computeCreate3Address(computeCreate3GuardedSalt(migratorSalt, msg.sender), createX);

        address migrator = ICreateX(createX)
            .deployCreate3(
                migratorSalt,
                abi.encodePacked(
                    type(UniswapV4MigratorSplit).creationCode,
                    abi.encode(airlock, poolManager, positionManager, locker, hookDeployedTo, topUpDistributor)
                )
            );

        address migratorHook = ICreateX(createX)
            .deployCreate3(
                hookSalt,
                abi.encodePacked(type(UniswapV4MigratorSplitHook).creationCode, abi.encode(poolManager, migrator))
            );
        require(migrator == migratorDeployedTo, "Unexpected Migrator deployed address");
        require(migratorHook == hookDeployedTo, "Unexpected Migrator Hook deployed address");

        vm.stopBroadcast();
        config.set("uniswap_v4_migrator", migrator);
        config.set("uniswap_v4_migrator_hook", migratorHook);
    }
}
