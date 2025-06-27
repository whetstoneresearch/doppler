/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { Airlock } from "src/Airlock.sol";
import { IPoolManager, IHooks } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager, PositionManager } from "@v4-periphery/PositionManager.sol";
import { MineV4MigratorHookParams, mineV4MigratorHook } from "test/shared/AirlockMiner.sol";

struct ScriptData {
    address airlock;
    address poolManager;
    address positionManager;
    address create2Factory;
    address streamableFeesLocker;
    address migratorHook;
}

/**
 * @title Doppler V4 Migrator Deployment Script
 * @notice Use this script if the rest of the protocol (Airlock and co) is already deployed
 */
abstract contract DeployV4MigratorOnlyScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Deploy migrator with pre-mined hook address
        UniswapV4Migrator uniswapV4Migrator = new UniswapV4Migrator(
            _scriptData.airlock,
            IPoolManager(_scriptData.poolManager),
            PositionManager(payable(_scriptData.positionManager)),
            StreamableFeesLocker(payable(_scriptData.streamableFeesLocker)),
            IHooks(_scriptData.migratorHook)
        );

        console.log(unicode"✨ UniswapV4Migrator was successfully deployed!");
        console.log("UniswapV4Migrator address: %s", address(uniswapV4Migrator));

        vm.stopBroadcast();
    }
}

contract DeployV4MigratorOnlyBaseSepoliaScript is DeployV4MigratorOnlyScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
            streamableFeesLocker: 0x3345E557c5C0b474bE1eb4693264008B8562Aa9c,
            migratorHook: 0x5D71D3a029Ff2e86831b3bA5fbb05F3703c2e000
        });
    }
}
