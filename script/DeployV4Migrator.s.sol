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
                    abi.encode(airlock, poolManager, positionManager, locker, hookDeployedTo)
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

/*
struct ScriptData {
    address airlock;
    address poolManager;
    address positionManager;
    address create2Factory;
}

abstract contract DeployV4MigratorScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        StreamableFeesLocker streamableFeesLocker = new StreamableFeesLocker(
            IPositionManager(_scriptData.positionManager), Airlock(payable(_scriptData.airlock)).owner()
        );

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
            streamableFeesLocker,
            IHooks(minedMigratorHook)
        );

        // Deploy hook with deployed migrator address
        UniswapV4MigratorSplitHook migratorHook =
            new UniswapV4MigratorSplitHook{ salt: salt }(IPoolManager(_scriptData.poolManager), uniswapV4Migrator);

        /// Verify that the hook was set correctly in the UniswapV4MigratorSplit constructor
        require(
            address(uniswapV4Migrator.migratorHook()) == address(migratorHook),
            "Migrator hook is not the expected address"
        );

        console.log(unicode"✨ StreamableFeesLocker was successfully deployed!");
        console.log("StreamableFeesLocker address: %s", address(streamableFeesLocker));

        console.log(unicode"✨ UniswapV4MigratorSplitHook was successfully deployed!");
        console.log("UniswapV4MigratorSplitHook address: %s", address(migratorHook));

        console.log(unicode"✨ UniswapV4MigratorSplit was successfully deployed!");
        console.log("UniswapV4MigratorSplit address: %s", address(uniswapV4Migrator));

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

contract DeployV4MigratorBaseSepoliaScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployV4MigratorUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
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

/// @dev forge script DeployV4MigratorUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployV4MigratorUnichainSepoliaScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            positionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployV4MigratorMonadTestnetScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $MONAD_TESTNET_RPC_URL
contract DeployV4MigratorMonadTestnetScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0xa82c66b6ddEb92089015C3565E05B5c9750b2d4B,
            poolManager: 0xe93882f395B0b24180855c68Ab19B2d78573ceBc,
            positionManager: 0xFBe792E485A7da8D7eE1CFB4986Fe99421aE825C,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployV4MigratorMonadMainnetScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $MONAD_MAINNET_RPC_URL
contract DeployV4MigratorMonadMainnetScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e,
            positionManager: 0x5b7eC4a94fF9beDb700fb82aB09d5846972F4016,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployV4MigratorMainnetScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $ETH_MAINNET_RPC_URL
contract DeployV4MigratorMainnetScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0000000000000000000000000000000000000000, // TODO: Replace me!
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployV4MigratorSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $ETH_SEPOLIA_RPC_URL
contract DeployV4MigratorSepoliaScript is DeployV4MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0000000000000000000000000000000000000000, // TODO: Replace me!
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}
*/