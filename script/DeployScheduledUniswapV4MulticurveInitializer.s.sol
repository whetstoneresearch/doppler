/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { computeCreate3Address, computeCreate3GuardedSalt, generateCreate3Salt } from "script/utils/CreateX.sol";
import { UniswapV4ScheduledMulticurveInitializer } from "src/initializers/UniswapV4ScheduledMulticurveInitializer.sol";
import {
    UniswapV4ScheduledMulticurveInitializerHook
} from "src/initializers/UniswapV4ScheduledMulticurveInitializerHook.sol";
import {
    MineV4MigratorHookParams,
    mineV4ScheduledMulticurveHook,
    mineV4ScheduledMulticurveHookCreate3
} from "test/shared/AirlockMiner.sol";

/**
 * @title Doppler Uniswap V4 Multicurve Initializer Deployment Script
 */
contract DeployUniswapV4ScheduledMulticurveInitializerScript is Script, Config {
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
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        (bytes32 hookSalt, address hookDeployedTo) = mineV4ScheduledMulticurveHookCreate3(msg.sender, createX);

        bytes32 initializerSalt = generateCreate3Salt(msg.sender, type(UniswapV4ScheduledMulticurveInitializer).name);
        address initializerDeployedTo =
            computeCreate3Address(computeCreate3GuardedSalt(initializerSalt, msg.sender), createX);

        address hook = ICreateX(createX)
            .deployCreate3(
                hookSalt,
                abi.encodePacked(
                    type(UniswapV4ScheduledMulticurveInitializerHook).creationCode,
                    abi.encode(poolManager, initializerDeployedTo)
                )
            );

        address initializer = ICreateX(createX)
            .deployCreate3(
                initializerSalt,
                abi.encodePacked(
                    type(UniswapV4ScheduledMulticurveInitializer).creationCode, abi.encode(airlock, poolManager, hook)
                )
            );

        require(hook == hookDeployedTo, "Unexpected Hook deployed address");
        require(initializer == initializerDeployedTo, "Unexpected Initializer deployed address");

        vm.stopBroadcast();
        config.set("uniswap_v4_scheduled_multicurve_hook", hook);
        config.set("uniswap_v4_scheduled_multicurve_initializer", initializer);
    }
}

/*
struct ScriptData {
    address airlock;
    address poolManager;
    address create2Factory;
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerBaseScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerBaseSepoliaScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerUnichainScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerUnichainSepoliaScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerMainnetScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $ETH_MAINNET_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerMainnetScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0xDe3599a2eC440B296373a983C85C365DA55d9dFA,
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}

/// @dev forge script DeployUniswapV4ScheduledMulticurveInitializerSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $ETH_SEPOLIA_RPC_URL
contract DeployUniswapV4ScheduledMulticurveInitializerSepoliaScript is
    DeployUniswapV4ScheduledMulticurveInitializerScript
{
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0xDe3599a2eC440B296373a983C85C365DA55d9dFA,
            poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
            create2Factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }
}
*/