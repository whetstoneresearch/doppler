/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { IPoolManager, IHooks } from "@v4-core/interfaces/IPoolManager.sol";
import { MineV4MigratorHookParams, mineV4MulticurveHook } from "test/shared/AirlockMiner.sol";

struct ScriptData {
    address airlock;
    address poolManager;
    address create2Factory;
}

/**
 * @title Doppler Uniswap V4 Multicurve Initializer Deployment Script
 */
abstract contract DeployUniswapV4MulticurveInitializerScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Using `CREATE` we can pre-compute the UniswapV4MulticurveInitializer address for mining the hook address
        address precomputedInitializer = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        /// Mine salt for Multicurve hook address
        (bytes32 salt, address minedHook) = mineV4MulticurveHook(
            MineV4MigratorHookParams({
                poolManager: _scriptData.poolManager,
                migrator: precomputedInitializer,
                hookDeployer: _scriptData.create2Factory
            })
        );

        // Deploy migrator with pre-mined hook address
        UniswapV4MulticurveInitializer initializer = new UniswapV4MulticurveInitializer(
            _scriptData.airlock, IPoolManager(_scriptData.poolManager), IHooks(minedHook)
        );

        // Deploy hook with deployed migrator address
        UniswapV4MulticurveInitializerHook hook =
            new UniswapV4MulticurveInitializerHook{ salt: salt }(IPoolManager(_scriptData.poolManager), initializer);

        /// Verify that the hook was set correctly in the UniswapV4Migrator constructor
        require(address(initializer.HOOK()) == address(hook), "Multicurve hook is not the expected address");

        vm.stopBroadcast();
    }
}

/// @dev forge script DeployUniswapV4MulticurveInitializerBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployUniswapV4MulticurveInitializerBaseScript is DeployUniswapV4MulticurveInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4MulticurveInitializerBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployUniswapV4MulticurveInitializerBaseSepoliaScript is DeployUniswapV4MulticurveInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4MulticurveInitializerUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployUniswapV4MulticurveInitializerUnichainScript is DeployUniswapV4MulticurveInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4MulticurveInitializerUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployUniswapV4MulticurveInitializerUnichainSepoliaScript is DeployUniswapV4MulticurveInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4MulticurveInitializerMonadTestnetScript --private-key $PRIVATE_KEY --slow --broadcast --rpc-url $MONAD_TESTNET_RPC_URL
contract DeployUniswapV4MulticurveInitializerMonadTestnetScript is DeployUniswapV4MulticurveInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0xe93882f395B0b24180855c68Ab19B2d78573ceBc,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}
