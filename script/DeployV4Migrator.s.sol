/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { Airlock } from "src/Airlock.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import { mineV4MigratorHookCreate3 } from "test/shared/AirlockMiner.sol";

contract DeployV4MigratorScript is Script, Config {
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
        address multisig = config.get("airlock_multisig").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();
        address positionManager = config.get("uniswap_v4_position_manager").toAddress();
        address topUpDistributor = config.get("top_up_distributor").toAddress();

        vm.startBroadcast();
        (bytes32 hookSalt, address hookDeployedTo) = mineV4MigratorHookCreate3(msg.sender, createX);

        bytes32 lockerSalt = generateCreate3Salt(msg.sender, type(StreamableFeesLocker).name);
        address lockerDeployedTo = computeCreate3Address(computeCreate3GuardedSalt(lockerSalt, msg.sender), createX);

        bytes32 migratorSalt = generateCreate3Salt(msg.sender, type(UniswapV4MigratorSplit).name);
        address migratorDeployedTo = computeCreate3Address(computeCreate3GuardedSalt(migratorSalt, msg.sender), createX);

        address locker = ICreateX(createX)
            .deployCreate3(
                lockerSalt,
                abi.encodePacked(type(StreamableFeesLocker).creationCode, abi.encode(positionManager, multisig))
            );

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
        require(locker == lockerDeployedTo, "Unexpected Locker deployed address");
        require(migrator == migratorDeployedTo, "Unexpected Migrator deployed address");
        require(migratorHook == hookDeployedTo, "Unexpected Migrator Hook deployed address");

        vm.stopBroadcast();
        config.set("streamable_fees_locker", locker);
        config.set("uniswap_v4_migrator", migrator);
        config.set("uniswap_v4_migrator_hook", migratorHook);
    }
}
