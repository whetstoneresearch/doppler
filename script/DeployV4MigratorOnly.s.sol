/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IHooks, IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { Script, console } from "forge-std/Script.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import { MineV4MigratorHookParams, mineV4MigratorHook } from "test/shared/AirlockMiner.sol";

struct ScriptData {
    address airlock;
    address poolManager;
    address positionManager;
    address create2Factory;
    address streamableFeesLocker;
    address topUpDistributor;
}

/**
 * @title Doppler V4 Migrator (and hook) Deployment Script
 * @notice Use this script if the rest of the protocol (Airlock and co) is already deployed
 * @dev Note that after deploying, the following steps must be performed:
 * - Approve the `UniswapV4MigratorSplit` as a `LiquidityMigrator` module in the Airlock
 * - Approve the `UniswapV4MigratorSplit` as a migrator in the `StreamableFeesLocker`
 */
abstract contract DeployV4MigratorOnlyScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Using `CREATE` we can pre-compute the UniswapV4MigratorSplit address for mining the hook address
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
        UniswapV4MigratorSplit uniswapV4Migrator = new UniswapV4MigratorSplit(
            _scriptData.airlock,
            IPoolManager(_scriptData.poolManager),
            PositionManager(payable(_scriptData.positionManager)),
            StreamableFeesLocker(payable(_scriptData.streamableFeesLocker)),
            IHooks(minedMigratorHook),
            TopUpDistributor(_scriptData.topUpDistributor)
        );

        // Deploy hook with deployed migrator address
        UniswapV4MigratorSplitHook migratorHook =
            new UniswapV4MigratorSplitHook{ salt: salt }(IPoolManager(_scriptData.poolManager), uniswapV4Migrator);

        /// Verify that the hook was set correctly in the UniswapV4MigratorSplit constructor
        require(
            address(uniswapV4Migrator.migratorHook()) == address(migratorHook),
            "Migrator hook is not the expected address"
        );

        vm.stopBroadcast();
    }
}

/// @dev forge script DeployV4MigratorOnlyBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployV4MigratorOnlyBaseSepoliaScript is DeployV4MigratorOnlyScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
            streamableFeesLocker: 0x3345E557c5C0b474bE1eb4693264008B8562Aa9c,
            topUpDistributor: address(0) // TODO: Replace me
        });
    }
}

/// @dev forge script DeployV4MigratorOnlyBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployV4MigratorOnlyBaseScript is DeployV4MigratorOnlyScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
            streamableFeesLocker: 0x0A00775D71a42cd33D62780003035e7F5b47bD3A,
            topUpDistributor: address(0) // TODO: Replace me
        });
    }
}

/// @dev forge script DeployV4MigratorOnlyUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployV4MigratorOnlyUnichainSepoliaScript is DeployV4MigratorOnlyScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            positionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
            streamableFeesLocker: 0x1728E8B3282502f275949109331E070b819B38eA,
            topUpDistributor: address(0) // TODO: Replace me
        });
    }
}

/// @dev forge script DeployV4MigratorOnlyUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployV4MigratorOnlyUnichainScript is DeployV4MigratorOnlyScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            positionManager: 0x4529A01c7A0410167c5740C487A8DE60232617bf,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
            streamableFeesLocker: 0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33,
            topUpDistributor: address(0) // TODO: Replace me
        });
    }
}
