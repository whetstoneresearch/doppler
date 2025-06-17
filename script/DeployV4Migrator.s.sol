/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { Airlock } from "src/Airlock.sol";
import { IPoolManager, IHooks } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager, PositionManager } from "@v4-periphery/PositionManager.sol";
import { MineV4MigratorHookParams, mineV4MigratorHook, computeCreate2Address } from "test/shared/AirlockMiner.sol";

struct ScriptData {
    address airlock;
    address poolManager;
    address positionManager;
    address airlockOwner;
}

struct MigratorSaltParams {
    address airlock;
    IPoolManager poolManager;
    IPositionManager positionManager;
    StreamableFeesLocker locker;
    IHooks migratorHook;
}

/**
 * @title Doppler V4 Migrator Deployment Script
 * @notice Use this script if the rest of the protocol (Airlock and co) is already deployed
 */
abstract contract DeployV4MigratorScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        StreamableFeesLocker streamableFeesLocker =
            new StreamableFeesLocker(IPositionManager(_scriptData.positionManager), _scriptData.airlockOwner);

        (bytes32 salt, address minedMigratorHook) = mineV4MigratorHook(
            MineV4MigratorHookParams({ poolManager: _scriptData.poolManager, hookDeployer: msg.sender })
        );

        MigratorSaltParams memory migratorSaltParams = MigratorSaltParams({
            airlock: _scriptData.airlock,
            poolManager: IPoolManager(_scriptData.poolManager),
            positionManager: IPositionManager(_scriptData.positionManager),
            locker: streamableFeesLocker,
            migratorHook: IHooks(minedMigratorHook)
        });

        // Pre-compute migrator address
        bytes32 migratorSalt = keccak256(abi.encode(migratorSaltParams));

        bytes32 migratorInitHash =
            keccak256(abi.encodePacked(type(UniswapV4Migrator).creationCode, abi.encode(migratorSaltParams)));
        address minedMigrator = computeCreate2Address(migratorSalt, migratorInitHash);

        // Deploy hook with pre-computed migrator address
        UniswapV4MigratorHook migratorHook = new UniswapV4MigratorHook{ salt: salt }(
            IPoolManager(_scriptData.poolManager), UniswapV4Migrator(payable(minedMigrator))
        );

        // Deploy migrator with actual hook address
        UniswapV4Migrator uniswapV4Migrator = new UniswapV4Migrator{ salt: migratorSalt }(
            migratorSaltParams.airlock,
            migratorSaltParams.poolManager,
            PositionManager(payable(address(migratorSaltParams.positionManager))),
            migratorSaltParams.locker,
            migratorSaltParams.migratorHook
        );

        require(
            address(uniswapV4Migrator.migratorHook()) == address(migratorHook),
            "Migrator hook is not the expected address"
        );

        console.log(unicode"✨ StreamableFeesLocker was successfully deployed!");
        console.log("StreamableFeesLocker address: %s", address(streamableFeesLocker));

        console.log(unicode"✨ UniswapV4MigratorHook was successfully deployed!");
        console.log("UniswapV4MigratorHook address: %s", address(migratorHook));

        console.log(unicode"✨ UniswapV4Migrator was successfully deployed!");
        console.log("UniswapV4Migrator address: %s", address(uniswapV4Migrator));

        vm.stopBroadcast();
    }
}

contract DeployV4MigratorBaseScript is DeployV4MigratorScript {
    function setUp() public override {
        address airlockOwner = Airlock(payable(0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12)).owner();
        require(airlockOwner == 0x21E2ce70511e4FE542a97708e89520471DAa7A66, "Airlock owner is not the expected address");

        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
            airlockOwner: 0x21E2ce70511e4FE542a97708e89520471DAa7A66
        });
    }
}
