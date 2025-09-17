// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { UniswapV4Initializer, DopplerDeployer, IPoolManager } from "src/UniswapV4Initializer.sol";
import { ChainIds } from "script/ChainIds.sol";

struct V4ScriptData {
    uint256 chainId;
    address airlock;
    address poolManager;
    address stateView;
}

/**
 * @title Doppler V4 Deployment Script
 * @notice Use this script if the rest of the protocol (Airlock and co) is already deployed
 */
abstract contract DeployV4Script is Script {
    V4ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.chainId == block.chainid, "Invalid chainId");
        vm.startBroadcast();
        DopplerDeployer dopplerDeployer = new DopplerDeployer(IPoolManager(_scriptData.poolManager));
        UniswapV4Initializer uniswapV4Initializer =
            new UniswapV4Initializer(_scriptData.airlock, IPoolManager(_scriptData.poolManager), dopplerDeployer);
        // DopplerLensQuoter quoter = new DopplerLensQuoter(IPoolManager(_scriptData.poolManager), IStateView(_scriptData.stateView));
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployV4BaseScript --private-key $PRIVATE_KEY --verify --rpc-url $BASE_MAINNET_RPC_URL --slow --broadcast
contract DeployV4BaseScript is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            chainId: ChainIds.BASE_MAINNET,
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            stateView: 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71
        });
    }
}

/// @dev forge script DeployV4BaseSepoliaScript --private-key $PRIVATE_KEY --verify --rpc-url $BASE_SEPOLIA_RPC_URL --slow --broadcast
contract DeployV4BaseSepoliaScript is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            chainId: ChainIds.BASE_SEPOLIA,
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4
        });
    }
}

contract DeployV4InkScript is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            chainId: ChainIds.INK_MAINNET,
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
            stateView: 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990
        });
    }
}

/// @dev forge script DeployV4UnichainScript --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_MAINNET_RPC_URL --slow --broadcast
contract DeployV4UnichainScript is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            chainId: ChainIds.UNICHAIN_MAINNET,
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            stateView: 0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2
        });
    }
}

/// @dev forge script DeployV4UnichainSepoliaScript --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --slow --broadcast
contract DeployV4UnichainSepoliaScript is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            chainId: ChainIds.UNICHAIN_SEPOLIA,
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            stateView: 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222
        });
    }
}
