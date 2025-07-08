/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { LockableUniswapV3Initializer } from "src/LockableUniswapV3Initializer.sol";

struct ScriptData {
    address airlock;
    address uniswapV3Factory;
}

abstract contract DeployLockableUniswapV3InitializerScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();

        LockableUniswapV3Initializer initializer =
            new LockableUniswapV3Initializer(_scriptData.airlock, IUniswapV3Factory(_scriptData.uniswapV3Factory));

        vm.stopBroadcast();
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerBaseSepolia --private-key $PRIVATE_KEY --verify --rpc-url $BASE_SEPOLIA_RPC_URL --slow --broadcast
contract DeployLockableUniswapV3InitializerBaseSepolia is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            uniswapV3Factory: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerBase --private-key $PRIVATE_KEY --verify --rpc-url $BASE_MAINNET_RPC_URL --slow --broadcast
contract DeployLockableUniswapV3InitializerBase is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            uniswapV3Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD
        });
    }
}
