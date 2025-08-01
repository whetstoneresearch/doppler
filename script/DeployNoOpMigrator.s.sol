// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { ChainIds } from "script/ChainIds.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
}

abstract contract DeployNoOpMigratorScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(_scriptData.airlock != address(0), "Airlock address not set");
        require(block.chainid == _scriptData.chainId, "Incorrect chainId");
        NoOpMigrator noOpMigrator = new NoOpMigrator(_scriptData.airlock);
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployNoOpMigratorBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployNoOpMigratorBaseScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12, chainId: ChainIds.BASE_MAINNET });
    }
}

/// @dev forge script DeployNoOpMigratorBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployNoOpMigratorBaseSepoliaScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e, chainId: ChainIds.BASE_SEPOLIA });
    }
}

/// @dev forge script DeployNoOpMigratorUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployNoOpMigratorUnichainSepoliaScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF, chainId: ChainIds.UNICHAIN_SEPOLIA });
    }
}

/// @dev forge script DeployNoOpMigratorUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployNoOpMigratorUnichainScript is DeployNoOpMigratorScript {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254, chainId: ChainIds.UNICHAIN_MAINNET });
    }
}
