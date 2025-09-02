// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
    address uniswapV2Factory;
    address uniswapV2Router;
}

abstract contract DeployUniV2MigratorScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(_scriptData.chainId == block.chainid, "Incorrect chainId");
        UniswapV2Migrator uniV2Migrator = new UniswapV2Migrator(
            _scriptData.airlock,
            IUniswapV2Factory(_scriptData.uniswapV2Factory),
            IUniswapV2Router02(_scriptData.uniswapV2Router),
            Airlock(payable(_scriptData.airlock)).owner()
        );
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployUniV2MigratorDomeTestnetScript --private-key $PRIVATE_KEY --rpc-url $DOMA_TESTNET_RPC_URL --slow --broadcast --verifier blockscout --verifier-url https://explorer-testnet.doma.xyz/api/
contract DeployUniV2MigratorDomeTestnetScript is DeployUniV2MigratorScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.DOMA_TESTNET,
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            uniswapV2Factory: 0xC99b485499f78995C6F1640dbB1413c57f8BA684,
            uniswapV2Router: 0xCe3099B2F07029b086E5e92a1573C5f5A3071783
        });
    }
}
