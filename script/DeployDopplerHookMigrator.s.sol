// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { MineDopplerHookMigratorParams, mineDopplerHookMigrator } from "test/shared/AirlockMiner.sol";

contract DeployDopplerHookMigratorScript is Script, Config {
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
        address multiSig = config.get("airlock_multisig").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();
        address topUpDistributor = config.get("top_up_distributor").toAddress();

        vm.startBroadcast();

        bytes32 lockerSalt = generateCreate3Salt(msg.sender, type(StreamableFeesLockerV2).name);
        address lockerDeployedTo = computeCreate3Address(computeCreate3GuardedSalt(lockerSalt, msg.sender), createX);
        address locker = ICreateX(createX)
            .deployCreate3(
                lockerSalt,
                abi.encodePacked(type(StreamableFeesLockerV2).creationCode, abi.encode(poolManager, multiSig))
            );
        require(locker == lockerDeployedTo, "Unexpected Locker address");

        (bytes32 migratorSalt, address migratorDeployedTo) =
            mineDopplerHookMigrator(MineDopplerHookMigratorParams({ sender: msg.sender, deployer: createX }));
        address dopplerHookMigrator = ICreateX(createX)
            .deployCreate3(
                migratorSalt,
                abi.encodePacked(
                    type(DopplerHookMigrator).creationCode, abi.encode(airlock, poolManager, locker, topUpDistributor)
                )
            );
        require(dopplerHookMigrator == migratorDeployedTo, "Unexpected deployed address");

        vm.stopBroadcast();
        config.set("doppler_hook_migrator", dopplerHookMigrator);
        config.set("streamable_fees_locker_v2", locker);
    }
}
