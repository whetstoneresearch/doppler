// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ICreateX } from "script/ICreateX.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";

contract DeployUniswapV4InitializerScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            deployToChain(chainId);
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address airlock = config.get("airlock").toAddress();
        address createX = config.get("create_x").toAddress();
        address poolManager = config.get("uniswap_v4_pool_manager").toAddress();

        vm.startBroadcast();
        bytes32 dopplerDeployerSalt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xbaaf));
        address dopplerDeployer = ICreateX(createX)
            .deployCreate3(
                dopplerDeployerSalt, abi.encodePacked(type(DopplerDeployer).creationCode, abi.encode(poolManager))
            );

        console.log("DopplerDeployer deployed to:", dopplerDeployer);
        config.set("doppler_deployer", dopplerDeployer);

        bytes32 uniswapV4InitializerSalt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0x001));
        address uniswapV4Initializer = ICreateX(createX)
            .deployCreate3(
                uniswapV4InitializerSalt,
                abi.encodePacked(
                    type(UniswapV4Initializer).creationCode, abi.encode(airlock, poolManager, dopplerDeployer)
                )
            );
        console.log("UniswapV4Initializer deployed to:", uniswapV4Initializer);
        config.set("uniswap_v4_initializer", uniswapV4Initializer);
        vm.stopBroadcast();
    }
}
