// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";

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
