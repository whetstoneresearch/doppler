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

        StreamableFeesLocker streamableFeesLocker = new StreamableFeesLocker(
            IPositionManager(_scriptData.positionManager), Airlock(payable(_scriptData.airlock)).owner()
        );

        // Using `CREATE` we can pre-compute the UniswapV4Migrator address for mining the hook address
        address precomputedUniswapV4Migrator = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        /// Mine salt for migrator hook address
        (bytes32 salt, address minedMigratorHook) = mineV4MigratorHook(
            MineV4MigratorHookParams({
                poolManager: _scriptData.poolManager,
                migrator: precomputedUniswapV4Migrator,
                hookDeployer: _scriptData.create2Factory
            })
        );

        // Deploy migrator with pre-mined hook address
        UniswapV4Migrator uniswapV4Migrator = new UniswapV4Migrator(
            _scriptData.airlock,
            IPoolManager(_scriptData.poolManager),
            PositionManager(payable(_scriptData.positionManager)),
            streamableFeesLocker,
            IHooks(minedMigratorHook)
        );

        // Deploy hook with deployed migrator address
        UniswapV4MigratorHook migratorHook =
            new UniswapV4MigratorHook{ salt: salt }(IPoolManager(_scriptData.poolManager), uniswapV4Migrator);

        /// Verify that the hook was set correctly in the UniswapV4Migrator constructor
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
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

contract DeployV4MigratorUnichainScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            positionManager: 0x4529A01c7A0410167c5740C487A8DE60232617bf,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}
