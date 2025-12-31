// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";

struct ScriptData {
    uint256 chainId;
    address dopplerHookInitializer;
    address poolManager;
}

abstract contract DeployRehypeDopplerHookScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.dopplerHookInitializer != address(0), "DopplerHookInitializer address not set");
        require(_scriptData.poolManager != address(0), "PoolManager address not set");
        require(block.chainid == _scriptData.chainId, "Incorrect chainId");

        vm.startBroadcast();
        RehypeDopplerHook rehypeDopplerHook = new RehypeDopplerHook(
            _scriptData.dopplerHookInitializer,
            IPoolManager(_scriptData.poolManager)
        );
        vm.stopBroadcast();

        console.log("RehypeDopplerHook deployed to:", address(rehypeDopplerHook));
        console.log("  - DopplerHookInitializer:", _scriptData.dopplerHookInitializer);
        console.log("  - PoolManager:", _scriptData.poolManager);
    }
}

/// @dev forge script DeployRehypeDopplerHookBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployRehypeDopplerHookBaseSepoliaScript is DeployRehypeDopplerHookScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.BASE_SEPOLIA,
            dopplerHookInitializer: 0x98CD6478DeBe443069dB863Abb9626d94de9A544,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
        });
    }
}

/// @dev forge script DeployRehypeDopplerHookBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployRehypeDopplerHookBaseScript is DeployRehypeDopplerHookScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.BASE_MAINNET,
            dopplerHookInitializer: address(0), // TODO: Add deployed DopplerHookInitializer address
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b
        });
    }
}

/// @dev forge script DeployRehypeDopplerHookUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployRehypeDopplerHookUnichainScript is DeployRehypeDopplerHookScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.UNICHAIN_MAINNET,
            dopplerHookInitializer: address(0), // TODO: Add deployed DopplerHookInitializer address
            poolManager: 0x1F98400000000000000000000000000000000004
        });
    }
}

/// @dev forge script DeployRehypeDopplerHookUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployRehypeDopplerHookUnichainSepoliaScript is DeployRehypeDopplerHookScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.UNICHAIN_SEPOLIA,
            dopplerHookInitializer: address(0), // TODO: Add deployed DopplerHookInitializer address
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
        });
    }
}

/// @dev forge script DeployRehypeDopplerHookMonadTestnetScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $MONAD_TESTNET_RPC_URL
contract DeployRehypeDopplerHookMonadTestnetScript is DeployRehypeDopplerHookScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.MONAD_TESTNET,
            dopplerHookInitializer: address(0), // TODO: Add deployed DopplerHookInitializer address
            poolManager: 0xe93882f395B0b24180855c68Ab19B2d78573ceBc
        });
    }
}
